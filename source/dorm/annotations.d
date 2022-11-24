module dorm.annotations;

import std.datetime;
import std.traits;
import std.meta;

enum autoCreateTime;
enum autoUpdateTime;
enum autoIncrement;
enum timestamp;
enum notNull;

alias Id = AliasSeq!(primaryKey, autoIncrement);

struct constructValue(alias fn) {}
struct validator(alias fn) {}

struct maxLength { int maxLength; }

alias AllowedDefaultValueTypes = AliasSeq!(
	string, ubyte[], byte, short, int, long, ubyte, ushort, uint, ulong, float,
	double, bool, Date, DateTime, TimeOfDay, SysTime
);
enum isAllowedDefaultValueType(T) = staticIndexOf!(T, AllowedDefaultValueTypes) != -1;
struct DefaultValue(T) { T value; }
auto defaultValue(T)(T value) if (isAllowedDefaultValueType!T)
{
	return DefaultValue!T(value);
}
alias PossibleDefaultValueTs = staticMap!(DefaultValue, AllowedDefaultValueTypes);

enum defaultFromInit;
enum primaryKey;
enum unique;

struct Choices { string[] choices; }
Choices choices(string[] choices...) { return Choices(choices.dup); }

struct columnName { string name; }

struct index
{
	// part of ctor
	static struct priority { int priority = 10; }
	static struct composite { string name; }

	// careful: never duplicate types here, otherwise the automatic ctor doesn't work
	priority _priority;
	composite _composite;

	this(T...)(T args)
	{
		foreach (ref field; this.tupleof)
		{
			static foreach (arg; args)
			{
				static if (is(typeof(field) == typeof(arg)))
					field = arg;
			}
		}
	}
}

enum embedded;
enum ignored;

/// Checks if the given attribute is part of this dorm.annotations module.
template isDormAttribute(alias attr)
{
	static if (is(typeof(attr) == DefaultValue!T, T))
		enum isDormAttribute = true;
	else static if (is(typeof(attr)))
		enum isDormAttribute = __traits(isSame, __traits(parent, typeof(attr)), dorm.annotations);
	else static if (is(attr == constructValue!fn, alias fn))
		enum isDormAttribute = true;
	else static if (is(attr == validator!fn, alias fn))
		enum isDormAttribute = true;
	else
		enum isDormAttribute = __traits(isSame, __traits(parent, attr), dorm.annotations);
}

/// Checks if the given attribute affects DORM Fields
enum isDormFieldAttribute(alias attr) = isDormAttribute!attr;

/// Checks if the given attribute affects DORM Models (classes)
enum isDormModelAttribute(alias attr) = isDormAttribute!attr;

/// Automatically generated foreign key attribute for one-to-many and many-to-many
/// relations. Does not need to be assigned onto any variables.
struct ForeignKeyImpl
{
	string table, column;
	ReferentialAction onUpdate; // TODO: decide on defaults
	ReferentialAction onDelete;
}

enum ReferentialAction
{
	restrict,
	cascade,
	setNull,
	setDefault
}

enum restrict = ReferentialAction.restrict;
enum cascade = ReferentialAction.cascade;
enum setNull = ReferentialAction.setNull;
enum setDefault = ReferentialAction.setDefault;

struct onUpdate
{
	ReferentialAction type;
}

struct onDelete
{
	ReferentialAction type;
}
