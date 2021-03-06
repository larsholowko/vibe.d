/**
	Helper module for vibe.http.rest that contains various utility templates and functions
	that use D static introspection capabilities. Separated to keep main module concentrated
	on HTTP/API related functionality. Is not intended for direct usage but some utilities here
	are pretty general.

	Some of the templates/functions may someday make their way into wider use.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Михаил Страшун
*/

module vibe.http.restutil;

import vibe.http.common;

import std.traits, std.string, std.algorithm, std.range, std.array;

public import std.typetuple, std.typecons;

///	Distinguishes getters from setters by their function signatures.
template isPropertyGetter(T)
{
	enum isPropertyGetter = (functionAttributes!(T) & FunctionAttribute.property) != 0
		&& !is(ReturnType!T == void);
}

/// Close relative of isPropertyGetter
template isPropertySetter(T)
{
	enum isPropertySetter = (functionAttributes!(T) & FunctionAttribute.property) != 0
		&& is(ReturnType!T == void);
}

unittest
{
	interface Sample
	{
		@property int getter();
		@property void setter(int);
		int simple();
	}

	static assert(isPropertyGetter!(typeof(&Sample.getter)));
	static assert(!isPropertyGetter!(typeof(&Sample.simple)));
	static assert(isPropertySetter!(typeof(&Sample.setter)));
}

/// Given some class or interface, reduces it to single base interface
template reduceToInterface(T)
	if (is(T == interface) || is(T == class))
{
	static if (is(T == interface))
		alias T reduceToInterface;
	else
	{
		alias Ifaces = InterfacesTuple!T;
		static if (Ifaces.length == 1)
			alias Ifaces[0] reduceToInterface;
		else
			static assert ("Type must be either provided as an interface or implement only one interface");
	}
}

unittest
{
	interface A { }
	class B : A { }
	static assert (is(reduceToInterface!A == A));
	static assert (is(reduceToInterface!B == A));
}

/**
  Small convenience wrapper to find and extract certain UDA from given type
Returns: null if UDA is not found, UDA value otherwise
 */
template extractUda(UDA, alias Symbol)
{
    private alias TypeTuple!(__traits(getAttributes, Symbol)) type_udas;

    private template extract(list...)
    {
        static if (!list.length)
            enum extract = null;
        else static if (is(typeof(list[0]) == UDA) || is(list[0] == UDA))
            enum extract = list[0];
        else
            enum extract = extract!(list[1..$]);
    }

    enum extractUda = extract!type_udas;
}

unittest
{
    struct Attr { int x; }
    @("something", Attr(42)) void decl();
    static assert (extractUda!(string, decl) == "something");
    static assert (extractUda!(Attr, decl) == Attr(42));
    static assert (extractUda!(int, decl) == null);
}

/**
	Clones function signature including its name so that resulting string
	can be mixed into descendant class to override it. All symbols in
	resulting string are fully qualified.
 */
template cloneFunction(alias Symbol)
	if (isSomeFunction!(Symbol))
{
	private:
		alias FunctionTypeOf!(Symbol) T;

		static if (is(T F == delegate) || isFunctionPointer!T)
			static assert(0, "Plain function or method symbol are expected");

	    // Phobos has fullyQualifiedName implementation for types only since 2.062
		import std.compiler;
    	alias std.traits.fullyQualifiedName fqn;

		static string addTypeQualifiers(string type)
		{
			enum {
				_const = 0,
				_immutable = 1,
				_shared = 2,
				_inout = 3
			}

			alias TypeTuple!(is(T == const), is(T == immutable), is(T == shared), is(T == inout)) qualifiers;
			
			auto result = type;
			if (qualifiers[_shared])
			{
				result = format("shared(%s)", result);
			}
			if (qualifiers[_const] || qualifiers[_immutable] || qualifiers[_inout])
			{
				result = format(
					"%s %s",
					result,
					qualifiers[_const] ? "const" : (qualifiers[_immutable] ? "immutable" : "inout")
                );
			}
			return result;
		}		

		template storageClassesString(uint psc)
		{
			alias ParameterStorageClass PSC;
			
			enum storageClassesString = format(
				"%s%s%s%s",
				psc & PSC.scope_ ? "scope " : "",
				psc & PSC.out_ ? "out " : "",
				psc & PSC.ref_ ? "ref " : "",
				psc & PSC.lazy_ ? "lazy " : ""
				);
		}
		
		string parametersString(alias T)()
		{
			if (!__ctfe)
				assert(false);
			
			alias ParameterTypeTuple!T parameters;
			alias ParameterStorageClassTuple!T parameterStC;
			alias ParameterIdentifierTuple!T parameterNames;
			
			string variadicStr;
			
			final switch (variadicFunctionStyle!T)
			{
				case Variadic.no:
				variadicStr = "";
				break;
				case Variadic.c:
				variadicStr = ", ...";
				break;
				case Variadic.d:
				variadicStr = parameters.length ? ", ..." : "...";
				break;
				case Variadic.typesafe:
				variadicStr = " ...";
				break;
			}
			
			static if (parameters.length)
			{
				string result = join(
					map!(a => format("%s%s %s", a[0], a[1], a[2]))(
						zip([staticMap!(storageClassesString, parameterStC)],
				            [staticMap!(fqn, parameters)],
			                [parameterNames])
					),
					", "
				);
				
				return result ~= variadicStr;
			}
			else
				return variadicStr;
		}
		
		template linkageString(T)
		{
			static if (functionLinkage!T != "D")
				enum string linkageString = format("extern(%s) ", functionLinkage!T);
			else
				enum string linkageString = "";
		}
		
		template functionAttributeString(T)
		{
			alias FunctionAttribute FA;
			enum attrs = functionAttributes!T;
			
			static if (attrs == FA.none)
				enum string functionAttributeString = "";
			else
				enum string functionAttributeString = format(
					"%s%s%s%s%s%s",
					attrs & FA.pure_ ? "pure " : "",
					attrs & FA.nothrow_ ? "nothrow " : "",
					attrs & FA.ref_ ? "ref " : "",
					attrs & FA.property ? "@property " : "",
					attrs & FA.trusted ? "@trusted " : "",
					attrs & FA.safe ? "@safe " : ""
				);
		}

	public:

		enum string cloneFunction = addTypeQualifiers(
			format(
				"%s%s%s %s(%s)",
				linkageString!T,
				functionAttributeString!T,
				fqn!(ReturnType!T),
				__traits(identifier, Symbol),
				parametersString!Symbol()				
			)
		);
}

unittest
{
	class Test : QualifiedNameTests
	{
		import core.vararg;

		override:
			//pragma(msg, generateAll!QualifiedNameTests);
			mixin(generateAll!QualifiedNameTests);
	}
}

/**
	Returns a tuple consisting of all symbols type T consists of
	that may need explicit qualification. Implementation is incomplete
	and tuned for REST interface generation needs.
 */
template getSymbols(T)
{
	import std.typetuple;

	static if (isAggregateType!T || is(T == enum))
	{
		alias TypeTuple!T getSymbols;
	}
	else static if (isStaticArray!T || isArray!T)
	{
		alias getSymbols!(typeof(T.init[0])) getSymbols;
	}
	else static if (isAssociativeArray!T)
	{
		alias TypeTuple!(getSymbols!(ValueType!T) , getSymbols!(KeyType!T)) getSymbols;
	}
	else static if (isPointer!T)
	{
		alias getSymbols!(PointerTarget!T) getSymbols;
	}
	else
		alias TypeTuple!() getSymbols;
}

unittest
{   
	alias QualifiedNameTests.Inner symbol;
	enum target1 = TypeTuple!(symbol).stringof;
	enum target2 = TypeTuple!(symbol, symbol).stringof;
	static assert(getSymbols!(symbol[10]).stringof == target1);
	static assert(getSymbols!(symbol[]).stringof == target1);
	static assert(getSymbols!(symbol).stringof == target1);
	static assert(getSymbols!(symbol[symbol]).stringof == target2);
	static assert(getSymbols!(int).stringof == TypeTuple!().stringof);
}

version(unittest)
{
	private:
		// data structure used in most unit tests
		interface QualifiedNameTests
		{
			static struct Inner
			{
			}

			const(Inner[]) func1(ref string name);
			ref int func1();
			shared(Inner[4]) func2(...) const;
			immutable(int[string]) func3(in Inner anotherName) @safe;
		}

		// helper for cloneFunction unit-tests that clones all method declarations of given interface,
		string generateAll(alias iface)()
		{
			if (!__ctfe)
				assert(false);

			string result;
			foreach (method; __traits(allMembers, iface))
			{
				foreach (overload; MemberFunctionsTuple!(iface, method))
				{
					result ~= cloneFunction!overload;
					result ~= "{ static typeof(return) ret; return ret; }";
					result ~= "\n";
				}
			}
			return result;
		}
}

/**
	For a given interface, finds all user-defined types
	used in its method signatures and generates list of
	module they originate from.
 */
string[] getRequiredImports(I)()
	if( is(I == interface) )
{
	if( !__ctfe )
		assert(false);

	bool[string] visited;
	string[] ret;

	void addModule(string name)
	{
		if (name !in visited) {
			ret ~= name;
			visited[name] = true;
		}
	}

	foreach( method; __traits(allMembers, I) ){
		foreach( overload; MemberFunctionsTuple!(I, method) ) {
			foreach( symbol; getSymbols!(ReturnType!overload) ) {
				static if( __traits(compiles, moduleName!symbol) )
					addModule(moduleName!symbol);
			}
			foreach( P; ParameterTypeTuple!overload ){
				foreach( symbol; getSymbols!P ){
					static if( __traits(compiles, moduleName!symbol) )
						addModule(moduleName!symbol);
				}
			}
		}
	}
	
	return ret;
}

unittest
{
	enum imports = getRequiredImports!QualifiedNameTests;
	static assert(imports.length == 1);
	static assert(imports[0] == "vibe.http.restutil");
}
