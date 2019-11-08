/**
 * JSON encoding.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.json;

import std.exception;
import std.string;
import std.traits;
import std.typecons;

import ae.utils.exception;
import ae.utils.meta;
import ae.utils.textout;

// ************************************************************************

struct JsonWriter(Output)
{
	/// You can set this to something to e.g. write to another buffer.
	Output output;

	private void putChars(S...)(S strings)
	{
		static if (is(typeof(output.put(strings))))
			output.put(strings);
		else
			foreach (str; strings)
				static if (is(typeof(output.put(str))))
					output.put(str);
				else
					foreach (dchar c; str)
					{
						alias C = char; // TODO: get char type of output
						C[4 / C.sizeof] buf = void;
						auto size = encode(buf, c);
						output.put(buf[0..size]);
					}
	}

	/// Write a string literal.
	private void putString(C)(in C[] s)
	{
		// TODO: escape Unicode characters?
		// TODO: Handle U+2028 and U+2029 ( http://timelessrepo.com/json-isnt-a-javascript-subset )

		output.put('"');
		auto start = s.ptr, p = start, end = start+s.length;

		while (p < end)
		{
			auto c = *p++;
			if (Escapes.escaped[c])
			{
				putChars(start[0..p-start-1], Escapes.chars[c]);
				start = p;
			}
		}

		putChars(start[0..p-start], '"');
	}

	/// Write a value of a simple type.
	void putValue(T)(T v)
	{
		static if (is(typeof(v is null)))
			if (v is null)
				return output.put("null");
		static if (is(T == typeof(null)))
			return output.put("null");
		else
		static if (isSomeString!T)
			putString(v);
		else
		static if (is(Unqual!T == bool))
			return output.put(v ? "true" : "false");
		else
		static if (is(Unqual!T : long))
			return .put(output, v);
		else
		static if (is(Unqual!T : real))
			return output.putFP(v);
		else
			static assert(0, "Don't know how to write " ~ T.stringof);
	}

	void beginArray()
	{
		output.put('[');
	}

	void endArray()
	{
		output.put(']');
	}

	void beginObject()
	{
		output.put('{');
	}

	void endObject()
	{
		output.put('}');
	}

	void putKey(in char[] key)
	{
		putString(key);
		output.put(':');
	}

	void putComma()
	{
		output.put(',');
	}
}

struct PrettyJsonWriter(Output, alias indent = '\t', alias newLine = '\n', alias pad = ' ')
{
	JsonWriter!Output jsonWriter;
	alias jsonWriter this;

	bool indentPending;
	uint indentLevel;

	void putIndent()
	{
		if (indentPending)
		{
			foreach (n; 0..indentLevel)
				output.put(indent);
			indentPending = false;
		}
	}

	void putNewline()
	{
		if (!indentPending)
		{
			output.put(newLine);
			indentPending = true;
		}
	}

	void putValue(T)(T v)
	{
		putIndent();
		jsonWriter.putValue(v);
	}

	void beginArray()
	{
		putIndent();
		jsonWriter.beginArray();
		indentLevel++;
		putNewline();
	}

	void endArray()
	{
		indentLevel--;
		putNewline();
		putIndent();
		jsonWriter.endArray();
	}

	void beginObject()
	{
		putIndent();
		jsonWriter.beginObject();
		indentLevel++;
		putNewline();
	}

	void endObject()
	{
		indentLevel--;
		putNewline();
		putIndent();
		jsonWriter.endObject();
	}

	void putKey(in char[] key)
	{
		putIndent();
		putString(key);
		output.put(pad, ':', pad);
	}

	void putComma()
	{
		jsonWriter.putComma();
		putNewline();
	}
}

struct CustomJsonSerializer(Writer)
{
	Writer writer;

	void put(T)(T v)
	{
		static if (is(T X == Nullable!X))
			if (v.isNull)
				writer.putValue(null);
			else
				put(v.get);
		else
		static if (is(T == enum))
			put(to!string(v));
		else
		static if (isSomeString!T || is(Unqual!T : real))
			writer.putValue(v);
		else
		static if (is(T == typeof(null)))
			writer.putValue(null);
		else
		static if (is(T U : U[]))
		{
			writer.beginArray();
			if (v.length)
			{
				put(v[0]);
				foreach (i; v[1..$])
				{
					writer.putComma();
					put(i);
				}
			}
			writer.endArray();
		}
		else
		static if (isTuple!T)
		{
			// TODO: serialize as object if tuple has names
			enum N = v.expand.length;
			static if (N == 0)
				return;
			else
			static if (N == 1)
				put(v.expand[0]);
			else
			{
				writer.beginArray();
				foreach (n; RangeTuple!N)
				{
					static if (n)
						writer.putComma();
					put(v.expand[n]);
				}
				writer.endArray();
			}
		}
		else
		static if (is(typeof(T.init.keys)) && is(typeof(T.init.values)) && is(typeof({string s = T.init.keys[0];})))
		{
			writer.beginObject();
			bool first = true;
			foreach (key, value; v)
			{
				if (!first)
					writer.putComma();
				else
					first = false;
				writer.putKey(key);
				put(value);
			}
			writer.endObject();
		}
		else
		static if (is(T==JSONFragment))
			writer.output.put(v.json);
		else
		static if (is(T==struct))
		{
			writer.beginObject();
			bool first = true;
			foreach (i, field; v.tupleof)
			{
				static if (!doSkipSerialize!(T, v.tupleof[i].stringof[2..$]))
				{
					static if (hasAttribute!(JSONOptional, v.tupleof[i]))
						if (v.tupleof[i] == T.init.tupleof[i])
							continue;
					if (!first)
						writer.putComma();
					else
						first = false;
					writer.putKey(getJsonName!(T, v.tupleof[i].stringof[2..$]));
					put(field);
				}
			}
			writer.endObject();
		}
		else
		static if (is(typeof(*v)))
		{
			if (v)
				put(*v);
			else
				writer.putValue(null);
		}
		else
			static assert(0, "Can't serialize " ~ T.stringof ~ " to JSON");
	}
}

alias JsonSerializer = CustomJsonSerializer!(JsonWriter!StringBuilder);

private struct Escapes
{
	static immutable  string[256] chars;
	static immutable bool[256] escaped;

	shared static this()
	{
		import std.string : format;

		escaped[] = true;
		foreach (c; 0..256)
			if (c=='\\')
				chars[c] = `\\`;
			else
			if (c=='\"')
				chars[c] = `\"`;
			else
			if (c=='\b')
				chars[c] = `\b`;
			else
			if (c=='\f')
				chars[c] = `\f`;
			else
			if (c=='\n')
				chars[c] = `\n`;
			else
			if (c=='\r')
				chars[c] = `\r`;
			else
			if (c=='\t')
				chars[c] = `\t`;
			else
			if (c<'\x20' || c == '\x7F' || c=='<' || c=='>' || c=='&')
				chars[c] = format(`\u%04x`, c);
			else
				chars[c] = [cast(char)c],
				escaped[c] = false;
	}
}

// ************************************************************************

string toJson(T)(T v)
{
	JsonSerializer serializer;
	serializer.put(v);
	return serializer.writer.output.get();
}

unittest
{
	struct X { int a; string b; }
	X x = {17, "aoeu"};
	assert(toJson(x) == `{"a":17,"b":"aoeu"}`, toJson(x));
	int[] arr = [1,5,7];
	assert(toJson(arr) == `[1,5,7]`);
	assert(toJson(true) == `true`);

	assert(toJson(tuple()) == ``);
	assert(toJson(tuple(42)) == `42`);
	assert(toJson(tuple(42, "banana")) == `[42,"banana"]`);
}

// ************************************************************************

string toPrettyJson(T)(T v)
{
	CustomJsonSerializer!(PrettyJsonWriter!StringBuilder) serializer;
	serializer.put(v);
	return serializer.writer.output.get();
}

unittest
{
	struct X { int a; string b; int[] c, d; }
	X x = {17, "aoeu", [1, 2, 3]};
	assert(toPrettyJson(x) ==
`{
	"a" : 17,
	"b" : "aoeu",
	"c" : [
		1,
		2,
		3
	],
	"d" : [
	]
}`, toPrettyJson(x));
}

// ************************************************************************

import std.ascii;
import std.utf;
import std.conv;

import ae.utils.text;

private struct JsonParser(C)
{
	C[] s;
	size_t p;

	Unqual!C next()
	{
		enforce(p < s.length, "Out of data while parsing JSON stream");
		return s[p++];
	}

	string readN(uint n)
	{
		string r;
		for (int i=0; i<n; i++)
			r ~= next();
		return r;
	}

	Unqual!C peek()
	{
		enforce(p < s.length, "Out of data while parsing JSON stream");
		return s[p];
	}

	@property bool eof() { return p == s.length; }

	void skipWhitespace()
	{
		while (isWhite(peek()))
			p++;
	}

	void expect(C c)
	{
		auto n = next();
		enforce(n==c, text("Expected ", c, ", got ", n));
	}

	T read(T)()
	{
		static if (is(T == typeof(null)))
			return readNull();
		else
		static if (is(T X == Nullable!X))
			return readNullable!X();
		else
		static if (is(T==enum))
			return readEnum!(T)();
		else
		static if (isSomeString!T)
			return readString().to!T;
		else
		static if (is(T==bool))
			return readBool();
		else
		static if (is(T : real))
			return readNumber!(T)();
		else
		static if (isDynamicArray!T)
			return readArray!(typeof(T.init[0]))();
		else
		static if (isStaticArray!T)
		{
			T result = readArray!(typeof(T.init[0]))()[];
			return result;
		}
		else
		static if (isTuple!T)
			return readTuple!T();
		else
		static if (is(typeof(T.init.keys)) && is(typeof(T.init.values)) && is(typeof(T.init.keys[0])==string))
			return readAA!(T)();
		else
		static if (is(T==JSONFragment))
		{
			auto start = p;
			skipValue();
			return JSONFragment(s[start..p]);
		}
		else
		static if (is(T==struct))
			return readObject!(T)();
		else
		static if (is(T U : U*))
			return readPointer!T();
		else
			static assert(0, "Can't decode " ~ T.stringof ~ " from JSON");
	}

	auto readTuple(T)()
	{
		// TODO: serialize as object if tuple has names
		enum N = T.expand.length;
		static if (N == 0)
			return T();
		else
		static if (N == 1)
			return T(read!(typeof(T.expand[0])));
		else
		{
			T v;
			expect('[');
			foreach (n, ref f; v.expand)
			{
				static if (n)
					expect(',');
				f = read!(typeof(f));
			}
			expect(']');
			return v;
		}
	}

	typeof(null) readNull()
	{
		expect('n');
		expect('u');
		expect('l');
		expect('l');
		return null;
	}

	auto readNullable(T)()
	{
		if (peek() == 'n')
		{
			readNull();
			return Nullable!T();
		}
		else
			return Nullable!T(read!T);
	}

	C[] readSimpleString() /// i.e. without escapes
	{
		skipWhitespace();
		expect('"');
		auto start = p;
		while (true)
		{
			auto c = next();
			if (c=='"')
				break;
			else
			if (c=='\\')
				throw new Exception("Unexpected escaped character");
		}
		return s[start..p-1];
	}

	C[] readString()
	{
		skipWhitespace();
		auto c = peek();
		if (c == '"')
		{
			next(); // '"'
			C[] result;
			auto start = p;
			while (true)
			{
				c = next();
				if (c=='"')
					break;
				else
				if (c=='\\')
				{
					result ~= s[start..p-1];
					switch (next())
					{
						case '"':  result ~= '"'; break;
						case '/':  result ~= '/'; break;
						case '\\': result ~= '\\'; break;
						case 'b':  result ~= '\b'; break;
						case 'f':  result ~= '\f'; break;
						case 'n':  result ~= '\n'; break;
						case 'r':  result ~= '\r'; break;
						case 't':  result ~= '\t'; break;
						case 'u':
						{
							wstring buf;
							goto Unicode_start;

							while (s[p..$].startsWith(`\u`))
							{
								p+=2;
							Unicode_start:
								buf ~= cast(wchar)fromHex!ushort(readN(4));
							}
							result ~= buf.to!(C[]);
							break;
						}
						default: enforce(false, "Unknown escape");
					}
					start = p;
				}
			}
			result ~= s[start..p-1];
			return result;
		}
		else
		if (isDigit(c) || c=='-') // For languages that don't distinguish numeric strings from numbers
		{
			static immutable bool[256] numeric =
			[
				'0':true,
				'1':true,
				'2':true,
				'3':true,
				'4':true,
				'5':true,
				'6':true,
				'7':true,
				'8':true,
				'9':true,
				'.':true,
				'-':true,
				'+':true,
				'e':true,
				'E':true,
			];

			auto start = p;
			while (numeric[c = peek()])
				p++;
			return s[start..p].dup;
		}
		else
		{
			foreach (n; "null")
				expect(n);
			return null;
		}
	}

	bool readBool()
	{
		skipWhitespace();
		if (peek()=='t')
		{
			enforce(readN(4) == "true", "Bad boolean");
			return true;
		}
		else
		if (peek()=='f')
		{
			enforce(readN(5) == "false", "Bad boolean");
			return false;
		}
		else
		{
			ubyte i = readNumber!ubyte();
			enforce(i < 2, "Bad digit for implicit number-to-bool conversion");
			return !!i;
		}
	}

	T readNumber(T)()
	{
		skipWhitespace();
		const(C)[] n;
		auto start = p;
		Unqual!C c = peek();
		if (c == '"')
			n = readSimpleString();
		else
		{
			while (c=='+' || c=='-' || (c>='0' && c<='9') || c=='e' || c=='E' || c=='.')
			{
				p++;
				if (eof) break;
				c = peek();
			}
			n = s[start..p];
		}
		static if (is(T : real))
			return to!T(n);
		else
			static assert(0, "Don't know how to parse numerical type " ~ T.stringof);
	}

	T[] readArray(T)()
	{
		skipWhitespace();
		expect('[');
		skipWhitespace();
		T[] result;
		if (peek()==']')
		{
			p++;
			return result;
		}
		while(true)
		{
			result ~= read!(T)();
			skipWhitespace();
			if (peek()==']')
			{
				p++;
				return result;
			}
			else
				expect(',');
		}
	}

	T readObject(T)()
	{
		skipWhitespace();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}

		while (true)
		{
			auto jsonField = readSimpleString();
			mixin(exceptionContext(q{"Error with field " ~ to!string(jsonField)}));
			skipWhitespace();
			expect(':');

			bool found;
			foreach (i, ref field; v.tupleof)
			{
				enum name = getJsonName!(T, v.tupleof[i].stringof[2..$]);
				if (name == jsonField)
				{
					field = read!(typeof(v.tupleof[i]))();
					found = true;
					break;
				}
			}

			if (!found)
			{
				static if (hasAttribute!(JSONPartial, T))
					skipValue();
				else
					throw new Exception(cast(string)("Unknown field " ~ jsonField));
			}

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readAA(T)()
	{
		skipWhitespace();
		static if (is(typeof(T.init is null)))
			if (peek() == 'n')
				return readNull();
		expect('{');
		skipWhitespace();
		T v;
		if (peek()=='}')
		{
			p++;
			return v;
		}
		alias K = typeof(v.keys[0]);

		while (true)
		{
			auto jsonField = readString();
			skipWhitespace();
			expect(':');

			v[jsonField.to!K] = read!(typeof(v.values[0]))();

			skipWhitespace();
			if (peek()=='}')
			{
				p++;
				return v;
			}
			else
				expect(',');
		}
	}

	T readEnum(T)()
	{
		return to!T(readSimpleString());
	}

	T readPointer(T)()
	{
		skipWhitespace();
		if (peek()=='n')
		{
			enforce(readN(4) == "null", "Null expected");
			return null;
		}
		alias S = typeof(*T.init);
		T v = new S;
		*v = read!S();
		return v;
	}

	void skipValue()
	{
		skipWhitespace();
		C c = peek();
		switch (c)
		{
			case '"':
				readString(); // TODO: Optimize
				break;
			case '0': .. case '9':
			case '-':
				readNumber!real(); // TODO: Optimize
				break;
			case '{':
				next();
				skipWhitespace();
				bool first = true;
				while (peek() != '}')
				{
					if (first)
						first = false;
					else
						expect(',');
					skipValue(); // key
					skipWhitespace();
					expect(':');
					skipValue(); // value
					skipWhitespace();
				}
				expect('}');
				break;
			case '[':
				next();
				skipWhitespace();
				bool first = true;
				while (peek() != ']')
				{
					if (first)
						first = false;
					else
						expect(',');
					skipValue();
					skipWhitespace();
				}
				expect(']');
				break;
			case 't':
				foreach (l; "true")
					expect(l);
				break;
			case 'f':
				foreach (l; "false")
					expect(l);
				break;
			case 'n':
				foreach (l; "null")
					expect(l);
				break;
			default:
				throw new Exception(text("Can't parse: ", c));
		}
	}
}

T jsonParse(T, C)(C[] s)
{
	auto parser = JsonParser!C(s);
	mixin(exceptionContext(q{format("Error at position %d", parser.p)}));
	return parser.read!T();
}

unittest
{
	struct S { int i; S[] arr; S* p0, p1; }
	S s = S(42, [S(1), S(2)], null, new S(15));
	auto s2 = jsonParse!S(toJson(s));
	//assert(s == s2); // Issue 3789
	assert(s.i == s2.i && s.arr == s2.arr && s.p0 is s2.p0 && *s.p1 == *s2.p1);
	jsonParse!S(toJson(s).dup);

	assert(jsonParse!(Tuple!())(``) == tuple());
	assert(jsonParse!(Tuple!int)(`42`) == tuple(42));
	assert(jsonParse!(Tuple!(int, string))(`[42, "banana"]`) == tuple(42, "banana"));

	assert(jsonParse!(string[string])(`null`) is null);
}

unittest
{
	struct T { string s; wstring w; dstring d; }
	T t;
	auto s = t.toJson;
	assert(s == `{"s":null,"w":null,"d":null}`, s);

	t.s = "foo";
	t.w = "bar"w;
	t.d = "baz"d;
	s = t.toJson;
	assert(s == `{"s":"foo","w":"bar","d":"baz"}`, s);

	jsonParse!T(s);
	jsonParse!T(cast(char[]) s);
	jsonParse!T(cast(const(char)[]) s);
	jsonParse!T(s.to!wstring);
	jsonParse!T(s.to!dstring);
}

// ************************************************************************

// TODO: migrate to UDAs

/**
 * A template that designates fields which should not be serialized to Json.
 *
 * Example:
 * ---
 * struct Point { int x, y, z; mixin NonSerialized!(x, z); }
 * assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
 * ---
 */
template NonSerialized(fields...)
{
	import ae.utils.meta : stringofArray;
	mixin(mixNonSerializedFields(stringofArray!fields()));
}

string mixNonSerializedFields(string[] fields)
{
	string result;
	foreach (field; fields)
		result ~= "enum bool " ~ field ~ "_nonSerialized = 1;";
	return result;
}

private template doSkipSerialize(T, string member)
{
	enum bool doSkipSerialize = __traits(hasMember, T, member ~ "_nonSerialized");
}

unittest
{
	struct Point { int x, y, z; mixin NonSerialized!(x, z); }
	assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
}

unittest
{
	enum En { one, two }
	assert(En.one.toJson() == `"one"`);
	struct S { int i1, i2; S[] arr1, arr2; string[string] dic; En en; mixin NonSerialized!(i2, arr2); }
	S s = S(42, 5, [S(1), S(2)], [S(3), S(4)], ["apple":"fruit", "pizza":"vegetable"], En.two);
	auto s2 = jsonParse!S(toJson(s));
	assert(s.i1 == s2.i1 && s2.i2 is int.init && s.arr1 == s2.arr1 && s2.arr2 is null && s.dic == s2.dic && s.en == En.two);
}

unittest
{
	alias B = Nullable!bool;
	B b;

	b = jsonParse!B("true");
	assert(!b.isNull);
	assert(b.get == true);
	assert(b.toJson == "true");

	b = jsonParse!B("false");
	assert(!b.isNull);
	assert(b.get == false);
	assert(b.toJson == "false");

	b = jsonParse!B("null");
	assert(b.isNull);
	assert(b.toJson == "null");

	struct S {}
	alias NS = Nullable!S;
	assert(NS.init.toJson == "null");
}

unittest // Issue 49
{
	immutable bool b;
	assert(toJson(b) == "false");
}

unittest
{
	import ae.utils.aa : OrderedMap;
	alias M = OrderedMap!(string, int);
	M m;
	m["one"] = 1;
	m["two"] = 2;
	auto j = (cast(const)m).toJson();
	assert(j == `{"one":1,"two":2}`, j);
	assert(j.jsonParse!M == m);
}

unittest
{
	assert(string.init.toJson.jsonParse!string  is null);
	assert(""         .toJson.jsonParse!string !is null);
}

unittest
{
	char[] s = "{}".dup;
	assert(s.jsonParse!(string[string]) == null);
}

unittest
{
	typeof(null) n;
	assert(n.toJson.jsonParse!(typeof(null)) is null);
}

unittest
{
	double f = 1.5;
	assert(f.toJson() == "1.5");
}

// ************************************************************************

/// User-defined attribute - specify name for JSON object field.
/// Useful when a JSON object may contain fields, the name of which are not valid D identifiers.
struct JSONName { string name; }

private template getJsonName(S, string FIELD)
{
	static if (hasAttribute!(JSONName, __traits(getMember, S, FIELD)))
		enum getJsonName = getAttribute!(JSONName, __traits(getMember, S, FIELD)).name;
	else
		enum getJsonName = FIELD;
}

// ************************************************************************

/// User-defined attribute - only serialize this field if its value is different from its .init value.
struct JSONOptional {}

unittest
{
	static struct S { @JSONOptional bool a=true, b=false; }
	assert(S().toJson == `{}`, S().toJson);
	assert(S(false, true).toJson == `{"a":false,"b":true}`);
}

// ************************************************************************

/// User-defined attribute - skip unknown fields when deserializing.
struct JSONPartial {}

unittest
{
	@JSONPartial static struct S { int b; }
	assert(`{"a":1,"b":2,"c":3.4,"d":[5,"x"],"de":[],"e":{"k":"v"},"ee":{},"f":true,"g":false,"h":null}`.jsonParse!S == S(2));
}

// ************************************************************************

/// Fragment of raw JSON.
/// When serialized, the .json field is inserted into the resulting
/// string verbatim, without any validation.
/// When deserialized, will contain the raw JSON of one JSON object of
/// any type.
struct JSONFragment
{
	string json;
	bool opCast(T)() const if (is(T==bool)) { return !!json; }
}

unittest
{
	JSONFragment[] arr = [JSONFragment(`1`), JSONFragment(`true`), JSONFragment(`"foo"`), JSONFragment(`[55]`)];
	assert(arr.toJson == `[1,true,"foo",[55]]`);
	assert(arr.toJson.jsonParse!(JSONFragment[]) == arr);
}
