# Copyright (c) 2015 Uber Technologies, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

from __future__ import absolute_import, unicode_literals, print_function

import struct
from io import BytesIO
from six.moves import range

from libc.stdint cimport (
    int8_t,
    int16_t,
    int32_t,
    int64_t,
)

from thriftrw.wire import TType
from thriftrw.wire.value cimport (
    ValueVisitor,
    Value,
    BoolValue,
    ByteValue,
    DoubleValue,
    I16Value,
    I32Value,
    I64Value,
    BinaryValue,
    FieldValue,
    StructValue,
    MapValue,
    MapItem,
    SetValue,
    ListValue,
)

from .core import Protocol
from ..errors import EndOfInputError
from ..errors import ThriftProtocolError


STRUCT_END = 0

class BinaryProtocolReader(object):
    """Parser for the binary protocol."""

    __slots__ = ('reader',)

    def __init__(self, reader):
        """Initialize the reader.

        :param reader:
            File-like object with a ``read(num)`` method which returns
            *exactly* the requested number of bytes.
        """
        self.reader = reader

    def read(self, typ):
        return self._reader(typ)(self)

    def _read(self, num_bytes):
        chunk = self.reader.read(num_bytes)
        if len(chunk) != num_bytes:
            raise EndOfInputError(
                'Expected %d bytes but got %d bytes.' %
                (num_bytes, len(chunk))
            )
        return chunk

    def _unpack(self, num_bytes, spec):
        """Unpack a single value using the given format and return it.

        :param num_bytes:
            Number of bytes to read.
        :param spec:
            Spec for ``struct.unpack``
        """
        (result,) = struct.unpack(spec, self._read(num_bytes))
        return result

    def _byte(self):
        return self._unpack(1, b'!b')

    def _i16(self):
        return self._unpack(2, b'!h')

    def _i32(self):
        return self._unpack(4, b'!i')

    def read_bool(self):
        """Reads a boolean."""
        return BoolValue(self._byte() == 1)

    def read_byte(self):
        """Reads a byte."""
        return ByteValue(self._byte())

    def read_double(self):
        """Reads a double."""
        return DoubleValue(self._unpack(8, b'!d'))

    def read_i16(self):
        """Reads a 16-bit integer."""
        return I16Value(self._i16())

    def read_i32(self):
        """Reads a 32-bit integer."""
        return I32Value(self._i32())

    def read_i64(self):
        """Reads a 64-bit integer."""
        return I64Value(self._unpack(8, b'!q'))

    def read_binary(self):
        """Reads a binary blob."""
        length = self._i32()
        return BinaryValue(self._read(length))

    def read_struct(self):
        """Reads an arbitrary Thrift struct."""
        fields = []

        field_type = self._byte()
        while field_type != STRUCT_END:
            field_id = self._i16()
            field_value = self.read(field_type)
            fields.append(
                FieldValue(
                    id=field_id,
                    ttype=field_type,
                    value=field_value,
                )
            )

            field_type = self._byte()
        return StructValue(fields)

    def read_map(self):
        """Reads a map."""
        key_ttype = self._byte()
        value_ttype = self._byte()
        length = self._i32()

        key_reader = self._reader(key_ttype)
        value_reader = self._reader(value_ttype)

        pairs = []
        for i in range(length):
            k = key_reader(self)
            v = value_reader(self)
            pairs.append(MapItem(k, v))

        return MapValue(
            key_ttype=key_ttype,
            value_ttype=value_ttype,
            pairs=pairs,
        )

    def read_set(self):
        """Reads a set."""
        value_ttype = self._byte()
        length = self._i32()

        value_reader = self._reader(value_ttype)
        values = []

        for i in range(length):
            values.append(value_reader(self))

        return SetValue(
            value_ttype=value_ttype,
            values=values
        )

    def read_list(self):
        """Reads a list."""
        value_ttype = self._byte()
        length = self._i32()

        value_reader = self._reader(value_ttype)
        values = []

        for i in range(length):
            values.append(value_reader(self))

        return ListValue(
            value_ttype=value_ttype,
            values=values
        )

    def _reader(self, typ):
        reader = self._readers.get(typ)
        if reader is None:
            raise ThriftProtocolError('Unknown TType "%r"' % typ)
        return reader

    # Mapping of TType to function that can read it.
    _readers = {
        TType.BOOL: read_bool,
        TType.BYTE: read_byte,
        TType.DOUBLE: read_double,
        TType.I16: read_i16,
        TType.I32: read_i32,
        TType.I64: read_i64,
        TType.BINARY: read_binary,
        TType.STRUCT: read_struct,
        TType.MAP: read_map,
        TType.SET: read_set,
        TType.LIST: read_list,
    }


cdef class BinaryProtocolWriter(ValueVisitor):
    """Serializes values using the Thrift Binary protocol."""

    __slots__ = ('writer',)

    cdef object writer  # TODO should be a typed buffer

    def __init__(self, writer):
        """Initialize the writer.

        :param writer:
            File-like object with ``write`` method.
        """
        self.writer = writer

    cpdef write(self, value):
        """Writes the given value.

        :param value:
            A ``Value`` object.
        """
        value.apply(self)

    def _pack(self, spec, value):
        """Pack the given value using ``struct.pack`` and write it.

        :param spec:
            Spec to pass to ``struct.pack``.
        :param value:
            Value to pack.
        """
        self.writer.write(struct.pack(spec, value))

    cpdef object visit_bool(self, bint value):  # bool:1
        self.visit_byte(1 if value else 0)

    cpdef object visit_byte(self, int8_t value):  # byte:1
        self._pack(b'!b', value)

    cpdef object visit_double(self, double value):  # double:8
        self._pack(b'!d', value)

    cpdef object visit_i16(self, int16_t value):  # i16:2
        self._pack(b'!h', value)

    cpdef object visit_i32(self, int32_t value):  # i32:4
        self._pack(b'!i', value)

    cpdef object visit_i64(self, int64_t value):  # i64:8
        self._pack(b'!q', value)

    cpdef object visit_binary(self, bytes value):  # len:4 str:len
        self.visit_i32(len(value))
        self.writer.write(value)

    cpdef object visit_struct(self, list fields):
        # ( type:1 id:2 value:* ){fields} '0'
        for field in fields:
            self.visit_byte(field.ttype)
            self.visit_i16(field.id)
            self.write(field.value)
        self.visit_byte(STRUCT_END)

    cpdef object visit_map(
        self, int8_t key_ttype, int8_t value_ttype, list pairs
    ):
        # key_type:1 value_type:1 count:4 (key:* value:*){count}
        self.visit_byte(key_ttype)
        self.visit_byte(value_ttype)
        self.visit_i32(len(pairs))

        for item in pairs:
            self.write(item.key)
            self.write(item.value)

    cpdef object visit_set(self, int8_t value_ttype, list values):
        # value_type:1 count:4 (item:*){count}
        self.visit_byte(value_ttype)
        self.visit_i32(len(values))

        for v in values:
            self.write(v)

    cpdef object visit_list(self, int8_t value_ttype, list values):
        # value_type:1 count:4 (item:*){count}
        self.visit_byte(value_ttype)
        self.visit_i32(len(values))

        for v in values:
            self.write(v)


class BinaryProtocol(Protocol):
    """Implements the Thrift binary protocol."""

    __slots__ = ()

    writer_class = BinaryProtocolWriter
    reader_class = BinaryProtocolReader

    def serialize_value(self, value):
        buff = BytesIO()
        writer = self.writer_class(buff)
        writer.write(value)
        return buff.getvalue()

    def deserialize_value(self, typ, s):
        buff = BytesIO(s)
        reader = self.reader_class(buff)
        return reader.read(typ)

__all__ = ['BinaryProtocol']
