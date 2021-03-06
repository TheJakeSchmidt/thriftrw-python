# Copyright (c) 2016 Uber Technologies, Inc.
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

from libc.stdint cimport (
    int8_t,
    int16_t,
    int32_t,
    int64_t,
)

from thriftrw.wire cimport ttype
from thriftrw.wire.message cimport Message

from thriftrw._buffer cimport ReadBuffer
from thriftrw._buffer cimport WriteBuffer
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

from .core cimport Protocol
from ..errors import EndOfInputError
from ..errors import ThriftProtocolError
from ._endian cimport (
    htobe16,
    htobe32,
    htobe64,
    be16toh,
    be32toh,
    be64toh,
)


cdef int8_t STRUCT_END = 0

cdef int32_t VERSION = 1

# Under strict mode, the version number is in most significant 16-bits of the
# 32-bit integer, and the most significant bit is set. This mask gets &-ed
# with the integer to get just the version number (it still needs to be
# shifted 16-bits to the right).
cdef int32_t VERSION_MASK = 0x7fff0000

# The least significant 8-bits of the 32-bit integer contain the type.
cdef int32_t TYPE_MASK = 0x000000ff


cdef class BinaryProtocolReader(object):
    """Parser for the binary protocol."""

    def __cinit__(self, ReadBuffer reader):
        """Initialize the reader.

        :param reader:
            File-like object with a ``read(num)`` method which returns
            *exactly* the requested number of bytes, or all remaining bytes if
            ``num`` is negative.
        """
        self.reader = reader

    cdef object _reader(self, int8_t typ):
        if typ == ttype.BOOL:
            return self.read_bool
        elif typ == ttype.BYTE:
            return self.read_byte
        elif typ == ttype.DOUBLE:
            return self.read_double
        elif typ == ttype.I16:
            return self.read_i16
        elif typ == ttype.I32:
            return self.read_i32
        elif typ == ttype.I64:
            return self.read_i64
        elif typ == ttype.BINARY:
            return self.read_binary
        elif typ == ttype.STRUCT:
            return self.read_struct
        elif typ == ttype.MAP:
            return self.read_map
        elif typ == ttype.SET:
            return self.read_set
        elif typ == ttype.LIST:
            return self.read_list
        else:
            raise ThriftProtocolError('Unknown TType "%r"' % typ)

    cpdef object read(self, int8_t typ):
        if typ == ttype.BOOL:
            return self.read_bool()
        elif typ == ttype.BYTE:
            return self.read_byte()
        elif typ == ttype.DOUBLE:
            return self.read_double()
        elif typ == ttype.I16:
            return self.read_i16()
        elif typ == ttype.I32:
            return self.read_i32()
        elif typ == ttype.I64:
            return self.read_i64()
        elif typ == ttype.BINARY:
            return self.read_binary()
        elif typ == ttype.STRUCT:
            return self.read_struct()
        elif typ == ttype.MAP:
            return self.read_map()
        elif typ == ttype.SET:
            return self.read_set()
        elif typ == ttype.LIST:
            return self.read_list()
        else:
            raise ThriftProtocolError('Unknown TType "%r"' % typ)

    cdef void _read(self, char* data, int count) except *:
        self.reader.read(data, count)

    cdef int8_t _byte(self) except *:
        cdef char c
        self._read(&c, 1)
        return <int8_t>c

    cdef int16_t _i16(self) except *:
        cdef char data[2]
        self._read(data, 2)
        return be16toh((<int16_t*>data)[0])

    cdef int32_t _i32(self) except *:
        cdef char data[4]
        self._read(data, 4)
        return be32toh((<int32_t*>data)[0])

    cdef int64_t _i64(self) except *:
        cdef char data[8]
        self._read(data, 8)
        return be64toh((<int64_t*>data)[0])

    cdef double _double(self) except *:
        cdef int64_t value = self._i64()
        return (<double*>(&value))[0]

    cdef Message read_message(self):
        cdef int8_t typ
        cdef int16_t version
        cdef int32_t size
        cdef bytes name

        size = self._i32()
        # TODO with cython, some of the Python-specific hacks around bit
        # twiddling can be skipped.
        if size < 0:
            # strict version:
            #
            #     versionAndType:4 name~4 seqid:4 payload
            version = (size & VERSION_MASK) >> 16
            if version != VERSION:
                raise ThriftProtocolError(
                    'Unsupported version "%r"' % version
                )
            typ = size & TYPE_MASK
            size = self._i32()
            name = self.reader.take(size)
        else:
            # non-strict version:
            #
            #     name:4 type:1 seqid:4 payload
            name = self.reader.take(size)
            typ = self._byte()

        seqid = self._i32()
        body = self.read(ttype.STRUCT)

        return Message(name=name, seqid=seqid, body=body, message_type=typ)

    cdef BoolValue read_bool(self):
        """Reads a boolean."""
        return BoolValue(self._byte() == 1)

    cdef ByteValue read_byte(self):
        """Reads a byte."""
        return ByteValue(self._byte())

    cdef DoubleValue read_double(self):
        """Reads a double."""
        return DoubleValue(self._double())

    cdef I16Value read_i16(self):
        """Reads a 16-bit integer."""
        return I16Value(self._i16())

    cdef I32Value read_i32(self):
        """Reads a 32-bit integer."""
        return I32Value(self._i32())

    cdef I64Value read_i64(self):
        """Reads a 64-bit integer."""
        return I64Value(self._i64())

    cdef BinaryValue read_binary(self):
        """Reads a binary blob."""
        cdef int32_t length = self._i32()
        return BinaryValue(self.reader.take(length))

    cdef StructValue read_struct(self):
        """Reads an arbitrary Thrift struct."""
        fields = []

        cdef int8_t field_type = self._byte()
        cdef int16_t field_id

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

    cdef MapValue read_map(self):
        """Reads a map."""
        cdef int8_t key_ttype = self._byte()
        cdef int8_t value_ttype = self._byte()
        cdef int32_t length = self._i32()

        kreader = self._reader(key_ttype)
        vreader = self._reader(value_ttype)

        pairs = []
        for i in range(length):
            k = kreader(self)
            v = vreader(self)
            pairs.append(MapItem(k, v))

        return MapValue(
            key_ttype=key_ttype,
            value_ttype=value_ttype,
            pairs=pairs,
        )

    cdef SetValue read_set(self):
        """Reads a set."""
        cdef int8_t value_ttype = self._byte()
        cdef int32_t length = self._i32()

        vreader = self._reader(value_ttype)

        values = []

        for i in range(length):
            values.append(vreader(self))

        return SetValue(
            value_ttype=value_ttype,
            values=values
        )

    cdef ListValue read_list(self):
        """Reads a list."""
        cdef int8_t value_ttype = self._byte()
        cdef int32_t length = self._i32()

        vreader = self._reader(value_ttype)

        values = []

        for i in range(length):
            values.append(vreader(self))

        return ListValue(
            value_ttype=value_ttype,
            values=values
        )


cdef class BinaryProtocolWriter(ValueVisitor):
    """Serializes values using the Thrift Binary protocol."""

    def __cinit__(self, WriteBuffer writer):
        """Initialize the writer.

        :param writer:
            WriteBuffer to which requests will be written.
        """
        self.writer = writer

    cpdef void write(self, Value value):
        """Writes the given value.

        :param value:
            A ``Value`` object.
        """
        value.apply(self)

    cdef _write(self, char* data, int length):
        self.writer.write(data, length)

    cdef object visit_bool(self, bint value):  # bool:1
        self.visit_byte(value)

    cdef object visit_byte(self, int8_t value):  # byte:1
        cdef char c = <char>value
        self._write(&c, 1)

    cdef object visit_double(self, double value):  # double:8
        # If confused:
        #
        #   <typ*>(&value)[0]
        #
        # Is just "interpret the in-memory representation of value as typ"
        self.visit_i64((<int64_t*>(&value))[0])

    cdef object visit_i16(self, int16_t value):  # i16:2
        value = htobe16(value)
        self._write(<char*>(&value), 2)

    cdef object visit_i32(self, int32_t value):  # i32:4
        value = htobe32(value)
        self._write(<char*>(&value), 4)

    cdef object visit_i64(self, int64_t value):  # i64:8
        value = htobe64(value)
        self._write(<char*>(&value), 8)

    cdef object visit_binary(self, bytes value):  # len:4 str:len
        self.visit_i32(len(value))
        self.writer.write_bytes(value)

    cdef object visit_struct(self, list fields):
        # ( type:1 id:2 value:* ){fields} '0'
        for field in fields:
            self.visit_byte(field.ttype)
            self.visit_i16(field.id)
            self.write(field.value)
        self.visit_byte(STRUCT_END)

    cdef object visit_map(
        self, int8_t key_ttype, int8_t value_ttype, list pairs
    ):
        # key_type:1 value_type:1 count:4 (key:* value:*){count}
        self.visit_byte(key_ttype)
        self.visit_byte(value_ttype)
        self.visit_i32(len(pairs))

        for item in pairs:
            self.write(item.key)
            self.write(item.value)

    cdef object visit_set(self, int8_t value_ttype, list values):
        # value_type:1 count:4 (item:*){count}
        self.visit_byte(value_ttype)
        self.visit_i32(len(values))

        for v in values:
            self.write(v)

    cdef object visit_list(self, int8_t value_ttype, list values):
        # value_type:1 count:4 (item:*){count}
        self.visit_byte(value_ttype)
        self.visit_i32(len(values))

        for v in values:
            self.write(v)

    cdef void write_message(self, Message message) except *:
        self.visit_binary(message.name)
        self.visit_byte(message.message_type)
        self.visit_i32(message.seqid)
        self.write(message.body)


cdef class BinaryProtocol(Protocol):
    """Implements the Thrift binary protocol."""

    cpdef bytes serialize_message(self, Message message):
        cdef WriteBuffer buff = WriteBuffer()
        BinaryProtocolWriter(buff).write_message(message)
        return buff.value

    cpdef Message deserialize_message(self, bytes s):
        cdef ReadBuffer buff = ReadBuffer(s)
        return BinaryProtocolReader(buff).read_message()

    cpdef bytes serialize_value(self, Value value):
        cdef WriteBuffer buff = WriteBuffer()
        BinaryProtocolWriter(buff).write(value)
        return buff.value

    cpdef Value deserialize_value(self, int typ, bytes s):
        cdef ReadBuffer buff = ReadBuffer(s)
        return BinaryProtocolReader(buff).read(typ)

__all__ = ['BinaryProtocol']
