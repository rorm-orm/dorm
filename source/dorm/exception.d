module dorm.exception;

/// Base clas for DORM exceptions
class DormException : Exception
{
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
	{
		super(msg, file, line, nextInChain);
	}
}

/// Thrown when DORM APIs are not used properly
class DormUsageException : DormException
{
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
	{
		super(msg, file, line, nextInChain);
	}
}

/// Thrown for errors coming from the DORM / RORM database implementation.
class DatabaseException : DormException
{
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
	{
		super(msg, file, line, nextInChain);
	}
}

/// Thrown when the model definition is wrong. (usually at compile time, not catchable)
class DormModelException : DormException
{
	///
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
	{
		super(msg, file, line, nextInChain);
	}
}

