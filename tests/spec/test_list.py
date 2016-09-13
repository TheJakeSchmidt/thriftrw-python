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

import pytest

from thriftrw.idl import Parser
from thriftrw.spec import primitive as prim_spec
from thriftrw.spec.list import ListTypeSpec
from thriftrw.spec.typedef import TypedefTypeSpec
from thriftrw.spec.spec_mapper import type_spec_or_ref
from thriftrw.wire import ttype

from ..util.value import vbinary, vlist


@pytest.fixture
def parse():
    return Parser(start='list_type', silent=True).parse


def test_mapper(parse):
    ast = parse('list<binary>')
    spec = type_spec_or_ref(ast)
    assert spec == ListTypeSpec(prim_spec.BinaryTypeSpec)


def test_link(parse, scope):
    ast = parse('list<Foo>')
    spec = type_spec_or_ref(ast)

    scope.add_type_spec(
        'Foo', TypedefTypeSpec('Foo', prim_spec.TextTypeSpec), 1
    )

    spec = spec.link(scope)
    assert spec.vspec == prim_spec.TextTypeSpec

    value = [u'foo', u'bar']
    assert spec.to_wire(value) == vlist(
        ttype.BINARY, vbinary(b'foo'), vbinary(b'bar')
    )
    assert value == spec.from_wire(spec.to_wire(value))


def test_primitive(parse, scope, loads):
    Foo = loads('struct Foo { 1: required i64 i }').Foo
    scope.add_type_spec('Foo', Foo.type_spec, 1)

    spec = type_spec_or_ref(parse('list<Foo>')).link(scope)

    value = [
        Foo(1234),
        Foo(1234567890),
        Foo(1234567890123456789),
    ]

    prim_value = [
        {'i': 1234},
        {'i': 1234567890},
        {'i': 1234567890123456789},
    ]

    assert spec.to_primitive(value) == prim_value
    assert spec.from_primitive(prim_value) == value


def test_from_primitive_invalid(parse, scope):
    spec = type_spec_or_ref(parse('list<i32>')).link(scope)

    with pytest.raises(ValueError):
        spec.from_primitive(['a', 'b', 'c'])


def test_validate():
    spec = ListTypeSpec(prim_spec.BinaryTypeSpec)
    spec.validate([b'a'])
    spec.validate([u'a'])

    with pytest.raises(TypeError):
        spec.validate(42)
