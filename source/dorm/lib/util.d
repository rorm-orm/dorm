module dorm.lib.util;

import core.sync.event;
import std.algorithm;
import std.functional;
import std.traits;
import std.typecons;

import dorm.lib.ffi;

/// Library-agnostic helper that's basically an Event. Exposes
/// - `set`
/// - `wait`
/// - `reset`
struct Awaiter
{
	version (Have_vibe_core)
	{
		import vibe.core.sync;

		shared(ManualEvent) event;
		int emitCount;

		void set() nothrow
		{
			event.emit();
		}

		void wait() nothrow
		{
			event.waitUninterruptible(emitCount);
		}

		void reset() nothrow @safe
		{
			emitCount = event.emitCount;
		}

		static Awaiter make() @trusted
		{
			auto ret = Awaiter(createSharedManualEvent);
			ret.emitCount = ret.event.emitCount;
			return ret;
		}
	}
	else
	{
		Event event;
		alias event this;

		static Awaiter make() @trusted
		{
			return Awaiter(Event(true, false));
		}
	}
}

struct FreeableAsyncResult(T)
{
	Awaiter awaiter;
	static if (is(T : void delegate(scope U value), U))
		T forward_callback;
	else static if (!is(T == void))
		T raw_result;
	Exception error;

	@disable this();

	this(Awaiter awaiter) @trusted
	{
		this.awaiter = move(awaiter);
	}

	static FreeableAsyncResult make() @trusted
	{
		return FreeableAsyncResult(Awaiter.make);
	}

	static if (is(T == void))
		alias Callback = extern(C) void function(void* data, scope RormError error) nothrow;
	else static if (is(T : void delegate(scope V value), V))
		alias Callback = extern(C) void function(void* data, scope V result, scope RormError error) nothrow;
	else static if (__traits(isPOD, T) || is(T == P*, P))
		alias Callback = extern(C) void function(void* data, T result, scope RormError error) nothrow;
	else static assert(false, "Unsupported async type " ~ T.stringof);

	Tuple!(Callback, void*) callback() return @safe
	{
		static if (is(T == void))
		{
			extern(C) static void ret(void* data, scope RormError error) nothrow
			{
				static if (DormFFITrace)
					debug dormTraceCallback(error);

				auto res = cast(FreeableAsyncResult*)data;
				if (error)
					res.error = error.makeException;
				res.awaiter.set();
			}
		}
		else static if (is(T : void delegate(scope U value), U))
		{
			extern(C) static void ret(void* data, scope U result, scope RormError error) nothrow
			{
				static if (DormFFITrace)
					debug dormTraceCallback(result, error);

				auto res = cast(FreeableAsyncResult*)data;
				if (error)
					res.error = error.makeException;
				else
				{
					try
					{
						res.forward_callback(result);
					}
					catch (Exception e)
					{
						res.error = e;
					}
				}
				res.awaiter.set();
			}
		}
		else
		{
			extern(C) static void ret(void* data, T result, scope RormError error) nothrow
			{
				static if (DormFFITrace)
					debug dormTraceCallback(result, error);

				auto res = cast(FreeableAsyncResult*)data;
				if (error)
					res.error = error.makeException;
				else
					res.raw_result = result;
				res.awaiter.set();
			}
		}

		return tuple(&ret, cast(void*)&this);
	}

	void waitAndThrow() @trusted
	{
		awaiter.wait();
		if (error)
			throw error;
	}

	auto result() @safe
	{
		waitAndThrow();
		static if (!is(T == void)
			&& !is(T : void delegate(scope U value), U))
			return raw_result;
	}

	void reset() @safe
	{
		(() @trusted => awaiter.reset())();
		static if (!is(T == void)
			&& !is(T : void delegate(scope U value), U))
			raw_result = T.init;
		error = null;
	}
}

auto sync_call(alias fn)(Parameters!fn[0 .. $ - 2] args) @trusted
{
	static assert(Parameters!(Parameters!fn[$ - 2]).length == 3
		|| Parameters!(Parameters!fn[$ - 2]).length == 2);
	static assert(is(Parameters!(Parameters!fn[$ - 2])[0] == void*));
	static assert(is(Parameters!(Parameters!fn[$ - 2])[$ - 1] == RormError));

	enum isVoid = Parameters!(Parameters!fn[$ - 2]).length == 2;

	struct Result
	{
		Exception exception;
		static if (!isVoid)
			Parameters!(Parameters!fn[$ - 2])[1] ret;
		bool sync;
	}

	Result result;

	extern(C) static void callback(Parameters!(Parameters!fn[$ - 2]) args) nothrow
	{
		static if (DormFFITrace)
			debug dormTraceSyncCallback(args[1 .. $]);

		auto result = cast(Result*)(args[0]);
		static if (!isVoid)
			auto data = args[1];
		auto error = args[$ - 1];
		if (error) result.exception = error.makeException;
		else {
			static if (!isVoid)
				result.ret = data;
		}
		result.sync = true;
	}
	fn(forward!args, &callback, &result);
	assert(result.sync, "called sync_call with function that does not call its callback in synchronous context!");

	if (result.exception)
		throw result.exception;

	static if (!isVoid)
		return result.ret;
}

template ffiInto(To)
{
	To ffiInto(From)(From v)
	{
		static assert(From.tupleof.length == To.tupleof.length,
			"FFI member fields count mismatch between "
			~ From.stringof ~ " and " ~ To.stringof);

		To ret;
		foreach (i, ref field; ret.tupleof)
		{
			static if (is(typeof(field) == FFIArray!T, T))
				field = FFIArray!T.fromData(v.tupleof[i]);
			else
				field = v.tupleof[i];
		}
		return ret;
	}
}
