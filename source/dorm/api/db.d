module dorm.api.db;

import dorm.declarative;
import dorm.declarative.conversion;
import dorm.exception;
import dorm.lib.util;
import dorm.model : Model;
import dorm.types;
import ffi = dorm.lib.ffi;

import std.algorithm : any, move;
import std.range : chain;
import std.conv : text, to;
import std.datetime : Clock, Date, DateTime, DateTimeException, SysTime, TimeOfDay, UTC;
import std.meta;
import std.range.primitives;
import std.traits;
import std.typecons : Nullable;

import mir.serde;
import mir.algebraic;

import core.attribute;
import core.time;

public import dorm.types : DormPatch;
public import dorm.lib.ffi : DBBackend;

public import dorm.api.condition;

static if (!is(typeof(mustuse)))
	private enum mustuse; // @suppress(dscanner.style.phobos_naming_convention)

/// Currently only a limited number of joins is supported per query, this could
/// configure it when it becomes a problem. This is due to a maximum number of
/// join aliases being available right now.
private enum maxJoins = 256;

/** 
 * Helper struct for `deserializeToml!BareConfiguration` to simply parse the
 * `database.toml` file without additional configuration.
 *
 * As user you can define your own configuration struct and simply add a member
 * `@serdeKeys("Database") DBConnectOptions database;` at the end to add your
 * own configuration options.
 */
struct BareConfiguration
{
	import mir.serde : serdeKeys;

	// make sure you put custom fields before database!

	/// only member, database settings
	@serdeKeys("Database") DBConnectOptions database;
}

/// Reads `filename` from disk as text, then deserializes it from TOML to `T`.
T parseTomlConfig(T)(string filename)
{
	import mir.toml;
	import std.file : readText, exists;

	if (!exists(filename))
		throw new DormException("TOML Configuration file '" ~ filename
			~ "' does not exist!");

	return readText(filename).deserializeToml!T;
}

/**
 * Configuration operation to connect to a database.
 *
 * See_Also: $(LREF SQLiteConnectOptions), $(LREF PostgresConnectOptions),
 * $(LREF MySQLConnectOptions)
 */
alias DBConnectOptions = Algebraic!(
	SQLiteConnectOptions,
	PostgresConnectOptions,
	MySQLConnectOptions
);

/// SQLite specific connection options
@serdeDiscriminatedField("Driver", "SQLite")
struct SQLiteConnectOptions
{
	/// Filename of the SQLite database
	@serdeKeys("Filename") string filename;
@serdeOptional:
	/// Minimal connections to initialize upfront. Must not be 0.
	@serdeKeys("MinConnections") uint minConnections = ffi.DBConnectOptions.init.minConnections;
	/// Maximum connections that allowed to be created. Must not be 0.
	@serdeKeys("MaxConnections") uint maxConnections = ffi.DBConnectOptions.init.maxConnections;
}

/// Postgres specific connection options
@serdeDiscriminatedField("Driver", "Postgres")
struct PostgresConnectOptions
{
	/// Name of the database.
	@serdeKeys("Name") string name;
	/// Host to connect to.
	@serdeKeys("Host") string host;
	/// Port to connect to.
	@serdeOptional
	@serdeKeys("Port") ushort port = 5432;
	/// Username to authenticate with.
	@serdeKeys("User") string user;
	/// Password to authenticate with.
	@serdeKeys("Password") string password;
@serdeOptional:
	/// Minimal connections to initialize upfront. Must not be 0.
	@serdeKeys("MinConnections") uint minConnections = ffi.DBConnectOptions.init.minConnections;
	/// Maximum connections that allowed to be created. Must not be 0.
	@serdeKeys("MaxConnections") uint maxConnections = ffi.DBConnectOptions.init.maxConnections;
}

/// MySQL specific connection options
@serdeDiscriminatedField("Driver", "MySQL")
struct MySQLConnectOptions
{
	/// Name of the database.
	@serdeKeys("Name") string name;
	/// Host to connect to.
	@serdeKeys("Host") string host;
	/// Port to connect to.
	@serdeOptional
	@serdeKeys("Port") ushort port = 3306;
	/// Username to authenticate with.
	@serdeKeys("User") string user;
	/// Password to authenticate with.
	@serdeKeys("Password") string password;
@serdeOptional:
	/// Minimal connections to initialize upfront. Must not be 0.
	@serdeKeys("MinConnections") uint minConnections = ffi.DBConnectOptions.init.minConnections;
	/// Maximum connections that allowed to be created. Must not be 0.
	@serdeKeys("MaxConnections") uint maxConnections = ffi.DBConnectOptions.init.maxConnections;
}

/**
 * High-level wrapper around a database. Through the driver implementation layer
 * this handles connection pooling and distributes work across a thread pool
 * automatically.
 *
 * Use the (UFCS) methods
 *
 * - $(LREF select)
 * - $(LREF update)
 * - $(LREF insert)
 *
 * to access the database.
 *
 * This struct cannot be copied, to pass it around, use `ref` or `move`. Once
 * the struct goes out of scope or gets unset, the connection to the database
 * will be freed.
 */
struct DormDB
{
@safe:
	private ffi.DBHandle _handle;

	/**
	 * Performs a Database connection (possibly in another thread) and returns
	 * the constructed DormDB handle once connected.
	 */
	this(DBConnectOptions options) @trusted
	{
		auto ffiOptions = options.match!(
			(SQLiteConnectOptions sqlite) {
				ffi.DBConnectOptions ret = {
					backend: ffi.DBBackend.SQLite,
					name: ffi.ffi(sqlite.filename),
					minConnections: sqlite.minConnections,
					maxConnections: sqlite.maxConnections
				};
				return ret;
			},
			(PostgresConnectOptions postgres) {
				ffi.DBConnectOptions ret = {
					backend: ffi.DBBackend.Postgres,
					name: ffi.ffi(postgres.name),
					host: ffi.ffi(postgres.host),
					port: postgres.port,
					user: ffi.ffi(postgres.user),
					password: ffi.ffi(postgres.password),
					minConnections: postgres.minConnections,
					maxConnections: postgres.maxConnections
				};
				return ret;
			},
			(MySQLConnectOptions mysql) {
				ffi.DBConnectOptions ret = {
					backend: ffi.DBBackend.MySQL,
					name: ffi.ffi(mysql.name),
					host: ffi.ffi(mysql.host),
					port: mysql.port,
					user: ffi.ffi(mysql.user),
					password: ffi.ffi(mysql.password),
					minConnections: mysql.minConnections,
					maxConnections: mysql.maxConnections
				};
				return ret;
			}
		);

		scope dbHandleAsync = FreeableAsyncResult!(ffi.DBHandle).make;
		ffi.rorm_db_connect(ffiOptions, dbHandleAsync.callback.expand);
		_handle = dbHandleAsync.result;
	}

	~this() @trusted
	{
		if (_handle)
		{
			ffi.rorm_db_free(_handle);
			_handle = null;
		}
	}

	@disable this(this);

	debug
	{
		private ffi.DBHandle handle() const @property
		{
			assert(_handle !is null, "Attempted to operate on uninitialized DormDB, please call constructor first!");
			return _handle;
		}
	}
	else
		private alias handle = _handle;

	/// Starts a database transaction, on which most operations can be called.
	///
	/// Gets automatically rolled back if commit isn't called and the
	/// transaction goes out of scope, but it's recommended to explicitly
	/// call `rollback` to clarify the intent.
	DormTransaction startTransaction() return
	{
		ffi.DBTransactionHandle txHandle;
		(() @trusted {
			auto ctx = FreeableAsyncResult!(ffi.DBTransactionHandle).make;
			ffi.rorm_db_start_transaction(this.handle, ctx.callback.expand);
			txHandle = ctx.result();
		})();
		return DormTransaction(&this, txHandle);
	}

	/// Database operation to INSERT a single value or multiple values when a
	/// slice is passed into `insert`.
	///
	/// It's possible to insert full Model instances, in which case every field
	/// of the model is used for the insertion. (also the primary key)
	///
	/// It's also possible to insert DormPatch instances to only pass the
	/// available fields into the SQL insert statement. This means default
	/// values will be auto-generated if possible.
	/// (see $(REF hasGeneratedDefaultValue, dorm,declarative,ModelFormat,Field))
	///
	/// This is the place where `@constructValue` constructors are called.
	///
	/// This method can also be used on transactions.
	void insert(T)(T value)
	if (!is(T == U[], U))
	{
		return (() @trusted => insertImpl!true(handle, (&value)[0 .. 1], null))();
	}

	/// ditto
	void insert(T)(scope T[] value)
	{
		return insertImpl!false(handle, value, null);
	}

	/**
	 * Returns a builder struct that can be used to perform an UPDATE statement
	 * in the SQL database on the provided Model table.
	 *
	 * See_Also: `DormTransaction.update`
	 */
	UpdateOperation!T update(T : Model)() return pure
	{
		return UpdateOperation!T(&this, null);
	}

	/**
	 * Returns a builder struct that can be used to perform a DELETE statement
	 * in the SQL database on the provided Model table.
	 *
	 * See_Also: `DormTransaction.remove`
	 */
	RemoveOperation!T remove(T : Model)() return pure
	{
		return RemoveOperation!T(&this, null);
	}

	/**
	 * Deletes the given model instance from the database.
	 *
	 * Equivalent to calling `db.remove!T.single(instance)`.
	 *
	 * See_Also: `RemoveOperation.single`
	 *
	 * Returns: true if anything was deleted, false otherwise.
	 */
	bool remove(T : Model)(T instance) return
	{
		return remove!T.single(instance);
	}

	/// ditto
	bool remove(TPatch)(TPatch instance) return
	if (!is(TPatch : Model) && isSomePatch!TPatch)
	{
		alias T = DBType!TPatch;
		return remove!T.single(instance);
	}

	/**
	 * This function executes a raw SQL statement.
	 *
	 * Iterate over the result using `foreach`.
	 *
	 * Statements are executed as prepared statements, if possible.
	 *
	 * To define placeholders, use `?` in SQLite and MySQL and $1, $n in Postgres.
	 * The corresponding parameters are bound in order to the query.
	 *
	 * The number of placeholder must match with the number of provided bind
	 * parameters.
	 *
	 * Params:
	 *     queryString = SQL statement to execute.
	 *     bindParams = Parameters to fill into placeholders of `queryString`.
	 *
	 * See_Also: `DormTransaction.rawSQL`
	 */
	RawSQLIterator rawSQL(
		scope return const(char)[] queryString,
		scope return ffi.FFIValue[] bindParams = null
	) return pure
	{
		return RawSQLIterator(&this, null, queryString, bindParams);
	}

	/** 
	 * Using a `ModelRef` as an argument this queries for the value referenced
	 * to by the foreign key. Assigns the result into the `ModelRef` field, so
	 * `field.populated` can be called by the user afterwards to work on the
	 * data that was queried with `populate`.
	 *
	 * Params:
	 *     field = a reference to a `ModelRef` variable or multiple by reference.
	 */
	void populate(T)(ref T field)
	{
		populateImpl(this, field);
	}

	/// ditto
	void populate(T)(T*[] field)
	{
		populateImpl(this, field);
	}
}

// defined this as global so that we can pass `Foo.fieldName` as alias argument,
// to have it be selected.
/**
 * Starts a builder struct that can be used to SELECT (query) data from the
 * database.
 *
 * It's possible to query full Model instances (get all fields), which are
 * allocated by the GC. It's also possible to only query parts of a Model, for
 * which DormPatch types are used, which is useful for improved query
 * performance when only using parts of a Model as well as reusing the data in
 * later update calls. (if the primary key is included in the patch)
 *
 * See `SelectOperation` for possible conditions and how to extract data.
 *
 * This method can also be used on transactions.
 */
static SelectOperation!(DBType!(Selection), SelectType!(Selection)) select(
	Selection...
)(
	return ref const DormDB db
) @trusted
{
	return typeof(return)(&db, null);
}

/// ditto
static SelectOperation!(DBType!(Selection), SelectType!(Selection)) select(
	Selection...
)(
	return ref const DormTransaction tx
) @trusted
{
	return typeof(return)(tx.db, tx.txHandle);
}

/// Helper struct that makes it possible to `foreach` over the `rawSQL` result.
@mustuse struct RawSQLIterator
{
	private DormDB* db;
	private ffi.DBTransactionHandle tx;
	private const(char)[] queryString;
	private ffi.FFIValue[] bindParams;
	private size_t rowCountImpl = -1;

	/// Returns the number of rows, only valid inside the foreach.
	size_t rowCount()
	{
		assert(rowCountImpl != -1, "Calling rowCount is only valid inside the foreach / opApply");
		return rowCountImpl;
	}

	// TODO: delegate with @safe / @system differences + index overloads + don't mark whole thing as @trusted
	/// Starts a new query and iterates all the results on each foreach call.
	int opApply(scope int delegate(scope RawRow row) dg) scope @trusted
	{
		scope (exit)
			rowCountImpl = -1;
		assert(rowCountImpl == -1, "Don't iterate over the same RawSQLIterator on multiple threads!");

		int result = 0;
		auto ctx = FreeableAsyncResult!(void delegate(scope ffi.FFIArray!(ffi.DBRowHandle))).make;
		ctx.forward_callback = (scope rows) {
			rowCountImpl = rows.size;
			foreach (row; rows[])
			{
				result = dg(RawRow(row));
				if (result)
					break;
			}
		};
		ffi.rorm_db_raw_sql(db.handle,
			tx,
			ffi.ffi(queryString),
			ffi.ffi(bindParams),
			ctx.callback.expand);
		ctx.result();
		return result;
	}

	/// Runs the raw SQL query, discarding results (throwing on error)
	void exec() scope
	{
		assert(rowCountImpl == -1, "Don't iterate over the same RawSQLIterator on multiple threads!");

		auto ctx = FreeableAsyncResult!(void delegate(scope ffi.FFIArray!(ffi.DBRowHandle))).make;
		ctx.forward_callback = (scope rows) {};
		ffi.rorm_db_raw_sql(db.handle,
			tx,
			ffi.ffi(queryString),
			ffi.ffi(bindParams),
			ctx.callback.expand);
		ctx.result();
	}
}

/// Allows column access on a raw DB row as returned by `db.rawSQL`.
struct RawRow
{
	private ffi.DBRowHandle row;

	@disable this(this);

	private static template ffiConvPrimitive(T)
	{
		static if (is(T == short))
			alias ffiConvPrimitive = ffi.rorm_row_get_i16;
		else static if (is(T == int))
			alias ffiConvPrimitive = ffi.rorm_row_get_i32;
		else static if (is(T == long))
			alias ffiConvPrimitive = ffi.rorm_row_get_i64;
		else static if (is(T == float))
			alias ffiConvPrimitive = ffi.rorm_row_get_f32;
		else static if (is(T == double))
			alias ffiConvPrimitive = ffi.rorm_row_get_f64;
		else static if (is(T == bool))
			alias ffiConvPrimitive = ffi.rorm_row_get_bool;
		else
			static assert(false, "Unsupported column type: " ~ T.stringof);
	}

	/// Gets the value of the column at the given column name assuming it is of
	/// the given type. If the value is not of the given type, an exception will
	/// be thrown.
	///
	/// Supported types:
	/// - any string type (auto-converted from strings / varchar)
	/// - `ubyte[]` for binary data
	/// - `short`, `int`, `long`, `float`, `double`, `bool`
	///
	/// For nullable values, use $(LREF opt) instead.
	T get(T)(scope const(char)[] column)
	{
		auto ffiColumn = ffi.ffi(column);
		ffi.RormError error;
		T result;

		static if (isSomeString!T)
		{
			auto slice = ffi.rorm_row_get_str(row, ffiColumn, error);
			if (!error)
			{
				static if (is(T : char[]))
					result = cast(T)slice[].dup;
				else
					result = slice[].to!T;
			}
		}
		else static if (is(T : ubyte[]))
		{
			auto slice = ffi.rorm_row_get_binary(row, ffiColumn, error);
			if (!error)
				result = cast(T)slice[].dup;
		}
		else
		{
			alias fn = ffiConvPrimitive!T;
			result = fn(row, ffiColumn, error);
		}

		if (error)
			throw error.makeException(" (in column '" ~ column.idup ~ "')");
		return result;
	}

	private static template ffiConvOptionalPrimitive(T)
	{
		static if (is(T == short))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_i16;
		else static if (is(T == int))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_i32;
		else static if (is(T == long))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_i64;
		else static if (is(T == float))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_f32;
		else static if (is(T == double))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_f64;
		else static if (is(T == bool))
			alias ffiConvOptionalPrimitive = ffi.rorm_row_get_null_bool;
		else
			static assert(false, "Unsupported column type: " ~ T.stringof);
	}

	/// Same as get, wraps primitives inside Nullable!T. Strings and ubyte[]
	/// binary arrays will return `null` (checkable with `is null`), but
	/// otherwise simply be embedded.
	auto opt(T)(scope const(char)[] column)
	{
		auto ffiColumn = ffi.ffi(column);
		ffi.RormError error;

		static if (isSomeString!T)
		{
			auto slice = ffi.rorm_row_get_null_str(row, ffiColumn, error);
			if (!error)
			{
				if (slice.isNull)
					return null;
				static if (is(T : char[]))
					return cast(T)slice.raw_value[].dup;
				else
					return slice.raw_value[].to!T;
			}
			else
				throw error.makeException(" (in column '" ~ column.idup ~ "')");
		}
		else static if (is(T : ubyte[]))
		{
			auto slice = ffi.rorm_row_get_null_binary(row, ffiColumn, error);
			if (slice.isNull)
				return null;
			if (!error)
				return cast(T)slice.raw_value[].dup;
			else
				throw error.makeException(" (in column '" ~ column.idup ~ "')");
		}
		else
		{
			Nullable!T result;
			alias fn = ffiConvOptionalPrimitive!T;
			auto opt = fn(row, ffiColumn, error);
			if (error)
				throw error.makeException(" (in column '" ~ column.idup ~ "')");
			if (!opt.isNull)
				result = opt.raw_value;
			return result;
		}
	}
}

/**
 * Wrapper around a Database transaction. Most methods that can be used on a
 * DormDB can also be used on a transaction.
 *
 * Performs a rollback when going out of scope and wasn't committed or rolled
 * back explicitly.
 */
struct DormTransaction
{
@safe:
	private DormDB* db;
	private ffi.DBTransactionHandle txHandle;

	@disable this(this);

	~this()
	{
		if (txHandle)
		{
			rollback();
		}
	}

	/// Commits this transaction, so the changes are recorded to the current
	/// database state.
	void commit()
	{
		scope (exit) txHandle = null;
		(() @trusted {
			auto ctx = FreeableAsyncResult!void.make;
			ffi.rorm_transaction_commit(txHandle, ctx.callback.expand);
			ctx.result();
		})();
	}

	/// Rolls back this transaction, so the DB changes are reverted to before
	/// the transaction was started.
	void rollback()
	{
		scope (exit) txHandle = null;
		(() @trusted {
			auto ctx = FreeableAsyncResult!void.make;
			ffi.rorm_transaction_rollback(txHandle, ctx.callback.expand);
			ctx.result();
		})();
	}

	/// Transacted variant of $(LREF DormDB.insert). Can insert a single value
	/// or multiple values at once.
	void insert(T)(T value)
	{
		return (() @trusted => insertImpl!true(db.handle, (&value)[0 .. 1], txHandle))();
	}

	/// ditto
	void insert(T)(scope T[] value)
	{
		return insertImpl!false(db.handle, value, txHandle);
	}

	/**
	 * This function executes a raw SQL statement.
	 *
	 * Iterate over the result using `foreach`.
	 *
	 * Statements are executed as prepared statements, if possible.
	 *
	 * To define placeholders, use `?` in SQLite and MySQL and $1, $n in Postgres.
	 * The corresponding parameters are bound in order to the query.
	 *
	 * The number of placeholder must match with the number of provided bind
	 * parameters.
	 *
	 * Params:
	 *     queryString = SQL statement to execute.
	 *     bindParams = Parameters to fill into placeholders of `queryString`.
	 *
	 * See_Also: `DormDB.rawSQL`
	 */
	RawSQLIterator rawSQL(
		scope return const(char)[] queryString,
		scope return ffi.FFIValue[] bindParams = null
	) return pure
	{
		return RawSQLIterator(db, txHandle, queryString, bindParams);
	}

	/**
	 * Returns a builder struct that can be used to perform an update statement
	 * in the SQL database on the provided Model table.
	 *
	 * See_Also: `DormDB.update`
	 */
	UpdateOperation!T update(T : Model)() return pure
	{
		return UpdateOperation!T(db, txHandle);
	}

	/**
	 * Returns a builder struct that can be used to perform a DELETE statement
	 * in the SQL database on the provided Model table.
	 *
	 * See_Also: `DormDB.remove`
	 */
	RemoveOperation!T remove(T : Model)() return pure
	{
		return RemoveOperation!T(db, txHandle);
	}

	/**
	 * Deletes the given model instance from the database inside the transaction.
	 *
	 * Equivalent to calling `tx.remove!T.single(instance)`.
	 *
	 * See_Also: `RemoveOperation.single`
	 *
	 * Returns: true if anything was deleted, false otherwise.
	 */
	bool remove(T : Model)(T instance) return
	{
		return remove!T.single(instance);
	}

	/// ditto
	bool remove(TPatch)(TPatch instance) return
	if (!is(TPatch : Model) && isSomePatch!TPatch)
	{
		alias T = DBType!TPatch;
		return remove!T.single(instance);
	}

	/** 
	 * Using a `ModelRef` as an argument this queries for the value referenced
	 * to by the foreign key. Assigns the result into the `ModelRef` field, so
	 * `field.populated` can be called by the user afterwards to work on the
	 * data that was queried with `populate`.
	 *
	 * Params:
	 *     field = a reference to a `ModelRef` variable or multiple by reference.
	 */
	void populate(T)(ref T field)
	{
		populateImpl(this, field);
	}

	/// ditto
	void populate(T)(T*[] field)
	{
		populateImpl(this, field);
	}
}

private void populateImpl(DB, T)(ref DB db, ref T field) @safe
if (isModelRef!T)
{
	field = db.select!(T.TSelect)
		.condition(c => __traits(getMember, c, T.primaryKeySourceName).equals(field.foreignKey))
		.findOne();
}

private void populateImpl(DB, T)(ref DB db, T*[] fields) @safe
if (isModelRef!T)
{
	import std.algorithm : map;

	auto q = db.select!(T.TSelect)
		.condition(c => __traits(getMember, c, T.primaryKeySourceName).among(fields.map!"a.foreignKey"));

	(() @trusted {
		foreach (row; q.stream())
			foreach (field; fields)
				if (field.foreignKey == mixin("row.", T.primaryKeySourceName))
					field.opAssign(row);
	})();
}

private string makePatchAccessPrefix(Patch, DB)()
{
	string ret;
	static if (!is(Patch == DB)
		&& is(__traits(parent, Patch) == DB))
	{
		static foreach (i, field; DB.tupleof)
		{
			static if (is(typeof(field) == Patch))
			{
				static foreach_reverse (j, field; DB.tupleof)
					static if (is(typeof(field) == Patch))
						static assert(i == j, "Multiple implicit "
							~ Patch.stringof ~ " patches on the same "
							~ DB.stringof ~ " Model class!");

				ret = DB.tupleof[i].stringof ~ ".";
			}
		}
	}
	return ret;
}

private void insertImpl(bool single, T)(
	scope ffi.DBHandle handle,
	scope T[] value,
	ffi.DBTransactionHandle transaction)
@safe
{
	import core.lifetime;
	alias DB = DBType!T;

	enum patchAccessPrefix = makePatchAccessPrefix!(T, DB);

	static stripPrefix(string s)
	{
		return patchAccessPrefix.length && s.length > patchAccessPrefix.length
			&& s[0 .. patchAccessPrefix.length] == patchAccessPrefix
			? s[patchAccessPrefix.length .. $] : s;
	}

	enum NumColumns = {
		int used;
		static foreach (field; DormFields!DB)
			static if (is(typeof(mixin("value[0]." ~ stripPrefix(field.sourceColumn)))) || field.hasConstructValue)
				used++;
		return used;
	}();

	ffi.FFIString[NumColumns] columns;
	static if (single)
	{
		ffi.FFIValue[NumColumns][1] values;
	}
	else
	{
		ffi.FFIValue[NumColumns][] values;
		values.length = value.length;

		if (!values.length)
			return;
	}

	int used;

	static if (!is(T == DB))
	{
		auto validatorObject = new DB();
		static if (!single)
		{
			DB validatorCopy;
			if (values.length > 1)
				(() @trusted => copyEmplace(validatorObject, validatorCopy))();
		}
	}

	static foreach (field; DormFields!DB)
	{{
		static if (is(typeof(mixin("value[0]." ~ stripPrefix(field.sourceColumn)))))
		{
			columns[used] = ffi.ffi(field.columnName);
			foreach (i; 0 .. values.length)
				values[i][used] = conditionValue!field(mixin("value[i]." ~ stripPrefix(field.sourceColumn)));
			used++;
		}
		else static if (field.hasConstructValue)
		{
			// filled in by constructor
			columns[used] = ffi.ffi(field.columnName);
			foreach (i; 0 .. values.length)
			{
				static if (is(T == DB))
					values[i][used] = conditionValue!field(mixin("value[i]." ~ field.sourceColumn));
				else
					values[i][used] = conditionValue!field(mixin("validatorObject." ~ stripPrefix(field.sourceColumn)));
			}
			used++;
		}
		else static if (field.hasGeneratedDefaultValue)
		{
			// OK
		}
		else static if (!is(T == DB))
			static assert(false, "Trying to insert a patch " ~ T.stringof
				~ " into " ~ DB.stringof ~ ", but it is missing the required field "
				~ stripPrefix(field.sourceReferenceName) ~ "! "
				~ "Fields with auto-generated values may be omitted in patch types. "
				~ ModelFormat.Field.humanReadableGeneratedDefaultValueTypes);
		else
			static assert(false, "wat? (defined DormField not found inside the Model class that defined it)");
	}}

	assert(used == NumColumns);

	static if (is(T == DB))
	{
		foreach (i; 0 .. values.length)
		{
			auto brokenFields = value[i].runValidators();

			string error;
			foreach (field; brokenFields)
			{
				static if (single)
					error ~= "Field `" ~ field.sourceColumn ~ "` defined in "
						~ field.definedAt.toString ~ " failed user validation.";
				else
					error ~= "row[" ~ i.to!string
						~ "] field `" ~ field.sourceColumn ~ "` defined in "
						~ field.definedAt.toString ~ " failed user validation.";
			}
			if (error.length)
				throw new DormException(error);
		}
	}
	else
	{
		foreach (i; 0 .. values.length)
		{
			static if (!single)
				if (i != 0)
					(() @trusted => copyEmplace(validatorCopy, validatorObject))();

			validatorObject.applyPatch(value[i]);
			auto brokenFields = validatorObject.runValidators();

			string error;
			foreach (field; brokenFields)
			{
				switch (field.columnName)
				{
					static foreach (sourceField; DormFields!DB)
					{
						static if (is(typeof(mixin("value[i]." ~ stripPrefix(sourceField.sourceColumn)))))
						{
							case sourceField.columnName:
						}
					}
					static if (single)
						error ~= "Field `" ~ field.sourceColumn ~ "` defined in "
							~ field.definedAt.toString ~ " failed user validation.";
					else
						error ~= "row[" ~ i.to!string
							~ "] field `" ~ field.sourceColumn ~ "` defined in "
							~ field.definedAt.toString ~ " failed user validation.";
					break;
				default:
					break;
				}
			}

			if (error.length)
				throw new DormException(error);
		}
	}


	(() @trusted {
		auto ctx = FreeableAsyncResult!void.make;
		static if (single)
		{
			ffi.rorm_db_insert(handle,
				transaction,
				ffi.ffi(DormLayout!DB.tableName),
				ffi.ffi(columns),
				ffi.ffi(values[0]), ctx.callback.expand);
		}
		else
		{
			auto rows = new ffi.FFIArray!(ffi.FFIValue)[values.length];
			foreach (i; 0 .. values.length)
				rows[i] = ffi.ffi(values[i]);

			ffi.rorm_db_insert_bulk(handle,
				transaction,
				ffi.ffi(DormLayout!DB.tableName),
				ffi.ffi(columns),
				ffi.ffi(rows), ctx.callback.expand);
		}
		ctx.result();
	})();
}

private struct ConditionBuilderData
{
	@disable this(this);

	JoinInformation joinInformation;
}

/// This is the type of the variable that is passed into the condition callback
/// at runtime on the `SelectOperation` struct. It automatically mirrors all
/// DORM fields that are defined on the passed-in `T` Model class.
///
/// Fields can be accessed with the same name they were defined in the Model
/// class. Embedded structs will only use the deepest variable name, e.g. a
/// nested field of name `userCommon.username` will only need to be accessed
/// using `username`. Duplicate / shadowing members is not implemented and will
/// be unable to use the condition builder on them.
///
/// If any boolean types are defined in the model, they can be quickly checked
/// to be false using the `not.booleanFieldName` helper.
/// See `NotConditionBuilder` for this.
///
/// When mistyping names, an expressive error message is printed as compile
/// time output, showing all possible members for convenience.
@mustuse
struct ConditionBuilder(T)
{
	private ConditionBuilderData* builderData;

	static foreach (field; DormFields!T)
	{
		static if (field.isForeignKey)
		{
			mixin("ForeignModelConditionBuilderField!(ModelRefOf!(T.", field.sourceColumn, "), field) ",
				field.sourceColumn.lastIdentifier,
				"() @property return { return typeof(return)(DormLayout!T.tableName, builderData); }");
		}
		else
		{
			mixin("ConditionBuilderField!(typeof(T.", field.sourceColumn, "), field) ",
				field.sourceColumn.lastIdentifier,
				" = ConditionBuilderField!(typeof(T.", field.sourceColumn, "), field)(`",
				DormLayout!T.tableName, "`, `", field.columnName,
				"`);");
		}
	}

	static if (__traits(allMembers, NotConditionBuilder!T).length > 1)
	{
		/// Helper to quickly create `field == false` conditions for boolean fields.
		NotConditionBuilder!T not;
	}
	else
	{
		/// Helper to quickly create `field == false` conditions for boolean fields.
		void not()() { static assert(false, "Model " ~ T.stringof
			~ " has no fields that can be used with .not"); }
	}

	mixin DynamicMissingMemberErrorHelper!"condition field";
}

/// This is the type of the variable that is passed into the `orderBy` callback
/// at runtime on the `SelectOperation` struct. It automatically mirrors all
/// DORM fields that are defined on the passed-in `T` Model class.
///
/// Fields can be accessed with the same name they were defined in the Model
/// class. Embedded structs will only use the deepest variable name, e.g. a
/// nested field of name `userCommon.username` will only need to be accessed
/// using `username`. Duplicate / shadowing members is not implemented and will
/// be unable to use the builder on them.
///
/// On the columns you can either use `.asc` to sort ascending or `.desc` to
/// sort descending by the column.
///
/// When mistyping names, an expressive error message is printed as compile
/// time output, showing all possible members for convenience.
@mustuse
struct OrderBuilder(T)
{
	private ConditionBuilderData* builderData;

	static foreach (field; DormFields!T)
	{
		static if (field.isForeignKey)
		{
			mixin("ForeignModelOrderBuilderField!(ModelRefOf!(T.", field.sourceColumn, "), field) ",
				field.sourceColumn.lastIdentifier,
				"() @property return { return typeof(return)(DormLayout!T.tableName, builderData); }");
		}
		else
		{
			mixin("OrderBuilderField!(typeof(T.", field.sourceColumn, "), field) ",
				field.sourceColumn.lastIdentifier,
				" = OrderBuilderField!(typeof(T.", field.sourceColumn, "), field)(`",
				DormLayout!T.tableName, "`, `", field.columnName,
				"`);");
		}
	}

	/// Only useful at runtime: when it's decided that no ordering needs to be
	/// done after all, simply return this method to do nothing.
	ffi.FFIOrderByEntry none() const @safe @property
	{
		return ffi.FFIOrderByEntry.init;
	}

	mixin DynamicMissingMemberErrorHelper!"order field";
}

/// This is the type of the variable that is passed into the `populate` callback
/// at runtime on the `SelectOperation` struct. It automatically mirrors all
/// DORM fields that are defined on the passed-in `T` Model class.
///
/// Fields can be accessed with the same name they were defined in the Model
/// class. Embedded structs will only use the deepest variable name, e.g. a
/// nested field of name `userCommon.username` will only need to be accessed
/// using `username`. Duplicate / shadowing members is not implemented and will
/// be unable to use the builder on them.
///
/// On the column you currently just need to write `.yes` after the column to
/// actually include it. This is a limitation because otherwise it wouldn't be
/// possible to populate both reference columns directly or references of
/// references. e.g. populating both `model.author` and `model.author.friends`
/// can be done by doing `model.author.yes` and `model.author.friends.yes`
///
/// When mistyping names, an expressive error message is printed as compile
/// time output, showing all possible members for convenience.
@mustuse
struct PopulateBuilder(T)
{
	private ConditionBuilderData* builderData;

	static foreach (field; DormFields!T)
	{
		static if (field.isForeignKey)
		{
			mixin("PopulateBuilderField!(ModelRefOf!(T.", field.sourceColumn, "), field) ",
				field.sourceColumn.lastIdentifier,
				"() @property return { return typeof(return)(DormLayout!T.tableName, builderData); }");
		}
	}

	mixin DynamicMissingMemberErrorHelper!"populate reference field";
}

/// This MUST be mixed in at the end to show proper members
private mixin template DynamicMissingMemberErrorHelper(string fieldName, string simplifyName = "")
{
	auto opDispatch(string member, string file = __FILE__, size_t line = __LINE__)()
	{
		import std.string : join;

		enum available = PublicMembers!(typeof(this)).filterBuiltins;

		enum suggestion = findSuggestion(available, member);
		enum suggestionMsg = suggestion.length ? "\n\n\t\tDid you mean " ~ suggestion ~ "?" : "";

		pragma(msg, errorBoldPrefix ~ file ~ "(" ~ line.to!string ~ "): " ~ supplErrorWithFilePrefix
			~ fieldName ~ " `" ~ member ~ "` does not exist on "
			~ (simplifyName.length ? simplifyName : typeof(this).stringof) ~ ". Available members are: "
			~ available.join(", ") ~ suggestionMsg);
		static assert(false, "See DORM error above.");
	}
}

private enum PublicMembers(T) = {
	string[] ret;
	static foreach (field; __traits(allMembers, T))
		static if (__traits(getProtection, __traits(getMember, T, field)) != "private")
			ret ~= field;
	return ret;
}();

private mixin template DisallowOperators(string typeName)
{
	auto opBinary(string op, R, string file = __FILE__, size_t line = __LINE__)(const R rhs)
	const @safe pure nothrow @nogc
	{
		pragma(msg, errorBoldPrefix ~ file ~ "(" ~ line.to!string ~ "): " ~ supplErrorWithFilePrefix
			~ "You are not supposed to use operators like '" ~ op ~ "' on "
			~ typeName ~ "! Use the operation fields on this instead.");
		static assert(false, "See DORM error above.");
	}

	auto opBinaryRight(string op, L, string file = __FILE__, size_t line = __LINE__)(const L lhs)
	const @safe pure nothrow @nogc
	{
		pragma(msg, errorBoldPrefix ~ file ~ "(" ~ line.to!string ~ "): " ~ supplErrorWithFilePrefix
			~ "You are not supposed to use operators like '" ~ op ~ "' on "
			~ typeName ~ "! Use the operation fields on this instead.");
		static assert(false, "See DORM error above.");
	}

	bool opEquals(R, string file = __FILE__, size_t line = __LINE__)(const R other)
	const @safe pure nothrow @nogc
	if (!is(immutable R == immutable typeof(this)))
	{
		pragma(msg, errorBoldPrefix ~ file ~ "(" ~ line.to!string ~ "): " ~ supplErrorWithFilePrefix
			~ "You are not supposed to use operators like '==' on "
			~ typeName ~ "! Use the operation fields on this instead.");
		static assert(false, "See DORM error above.");
	}
}

private string[] filterBuiltins(string[] members)
{
	import std.algorithm : among, remove;

	foreach_reverse (i, member; members)
		if (member.among("__ctor", "__dtor", "opDispatch"))
			members = members.remove(i);
	return members;
}

private string findSuggestion(string[] available, string member)
{
	// TODO: levenshteinDistance doesn't work at CTFE
	// import std.algorithm : levenshteinDistance;

	// size_t minDistance = size_t.max;
	// string suggestion;

	// foreach (a; available)
	// {
	// 	auto dist = levenshteinDistance(a, member);
	// 	if (dist < minDistance)
	// 	{
	// 		suggestion = a;
	// 		minDistance = dist;
	// 	}
	// }
	// return minDistance < 3 ? suggestion : null;

	import std.string : soundex;

	char[4] q, test;
	if (!soundex(member, q[]))
		return null;
	foreach (a; available)
	{
		auto t = soundex(a, test[]);
		if (t == q)
			return a;
	}
	return null;
}

private enum errorBoldPrefix = "\x1B[1m";
private enum supplErrorWithFilePrefix = "\x1B[1;31mDORM Error:\x1B[m ";
private enum supplErrorPrefix = "           " ~ supplErrorWithFilePrefix;

/// Helper type to quickly create `field == false` conditions for boolean fields.
///
/// See `ConditionBuilder`
@mustuse
struct NotConditionBuilder(T)
{
	static foreach (field; DormFields!T)
	{
		static if (is(typeof(mixin("T.", field.sourceColumn)) : bool))
		{
			mixin("Condition ",
				field.sourceColumn.lastIdentifier,
				"() @property { return Condition(UnaryCondition(UnaryConditionType.Not,
					makeColumnReference(`",
				DormLayout!T.tableName, "`, `", field.columnName,
				"`))); }");
		}
	}

	mixin DynamicMissingMemberErrorHelper!"negated condition field";
}

private Condition* makeColumnReference(string tableName, string columnName) @safe
{
	// TODO: think of how we can abstract memory allocation here
	return new Condition(columnValue(tableName, columnName));
}

private Condition* makeConditionConstant(ModelFormat.Field fieldInfo, T)(T value) @safe
{
	// TODO: think of how we can abstract memory allocation here
	return new Condition(conditionValue!fieldInfo(value));
}

private mixin template ForeignJoinHelper()
{
	private string srcTableName;
	private ConditionBuilderData* builderData;

	/// Constructs this ForeignModelConditionBuilderField, operating on the given data pointer during its lifetime
	this(string srcTableName, ConditionBuilderData* builderData) @safe
	{
		this.srcTableName = srcTableName;
		this.builderData = builderData;
	}

	private string ensureJoined() @safe
	{
		return builderData.joinInformation.joinSuppl[ensureJoinedIdx].placeholder;
	}

	private size_t ensureJoinedIdx() @trusted
	{
		auto ji = &builderData.joinInformation;
		string fkName = field.columnName;
		auto exist = fkName in ji.joinedTables;
		if (exist)
		{
			return *exist;
		}
		else
		{
			size_t index = ji.joins.length;
			assert(ji.joinSuppl.length == index);
			string placeholder = JoinInformation.joinAliasList[ji.joinedTables.length];
			ffi.FFICondition* condition = new ffi.FFICondition();
			condition.type = ffi.FFICondition.Type.BinaryCondition;
			condition.binaryCondition.type = ffi.FFIBinaryCondition.Type.Equals;
			auto lhs = new ffi.FFICondition();
			auto rhs = new ffi.FFICondition();
			lhs.type = ffi.FFICondition.Type.Value;
			lhs.value = columnValue(placeholder, ModelRef.primaryKeyColumnName);
			rhs.type = ffi.FFICondition.Type.Value;
			rhs.value = columnValue(srcTableName, field.columnName);
			condition.binaryCondition.lhs = lhs;
			condition.binaryCondition.rhs = rhs;

			assert(ji.joins.length == index,
				"this method must absolutely never be called in parallel on the same object");
			ji.joinedTables[fkName] = index;
			ji.joins ~= ffi.FFIJoin(
				ffi.FFIJoinType.join,
				ffi.ffi(DormLayout!RefDB.tableName),
				ffi.ffi(placeholder),
				condition
			);
			ji.joinSuppl ~= JoinInformation.JoinSuppl(
				placeholder,
				false
			);
			return index;
		}
	}
}

/// Helper type to access sub-fields through `ModelRef` foreign key fields. Will
/// join the foreign model table automatically if using any fields on there,
/// other than the primary key, which can be read directly from the source.
///
/// Just like `ConditionBuilder` this automatically mirrors all DORM fields of
/// the _foreign_ table, i.e. the referenced model type.
///
/// This type is returned by the `ConditionBuilder`. It does not define any
/// members itself, it only defines all members of the referenced Model to be
/// accessible. When operating on the primary key that is referenced to from the
/// ModelRef foreign key, no join operation will be enforced, as the data is
/// stored entirely in the table with the foreign key.
@mustuse
struct ForeignModelConditionBuilderField(ModelRef, ModelFormat.Field field)
{
	alias RefDB = ModelRef.TModel;

	mixin ForeignJoinHelper;

	static foreach (subfield; DormFields!RefDB)
	{
		static if (__traits(isSame, ModelRef.primaryKeyAlias, mixin("RefDB.", subfield.sourceColumn)))
		{
			mixin("ConditionBuilderField!(ModelRef.PrimaryKeyType, field) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property @safe return { return ConditionBuilderField!(ModelRef.PrimaryKeyType, field)(srcTableName, `",
				field.columnName, "`); }
				
				private alias _foreignKeyField = ", subfield.sourceColumn.lastIdentifier, ";");
		}
		else static if (subfield.isForeignKey)
		{
			mixin("ForeignModelConditionBuilderField!(ModelRefOf!(RefDB.", subfield.sourceColumn, "), subfield) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property return { string placeholder = ensureJoined(); return typeof(return)(placeholder, builderData); }");
		}
		else
		{
			mixin("ConditionBuilderField!(typeof(RefDB.", subfield.sourceColumn, "), subfield) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property @safe return { string placeholder = ensureJoined(); return typeof(return)(placeholder, `",
				subfield.columnName,
				"`); }");
		}
	}

	static if (!__traits(hasMember, typeof(this), "refersTo"))
	{
		/// Compares the foreign key to be equal to the primary key of `other`
		Condition refersTo(T)(T other)
		if (is(T == RefDB) || isSomePatch!T)
		{
			mixin ValidatePatch!(T, RefDB);

			static assert(is(typeof(mixin("other.", ModelRef.primaryKeySourceName))),
				"Primary key '" ~ ModelRef.primaryKeySourceName
				~ "' must be included in patch type "
				~ T.stringof ~ " in order to be a valid argument to remove!");

			return mixin("_foreignKeyField.equals(other."
				~ ModelRef.primaryKeySourceName ~ ")");
		}
	}

	static if (!__traits(hasMember, typeof(this), "notRefersTo"))
	{
		/// Compares the foreign key to be not equal to the primary key of `other`
		Condition notRefersTo(T)(T other)
		if (is(T == RefDB) || isSomePatch!T)
		{
			mixin ValidatePatch!(T, RefDB);

			static assert(is(typeof(mixin("other.", ModelRef.primaryKeySourceName))),
				"Primary key '" ~ ModelRef.primaryKeySourceName
				~ "' must be included in patch type "
				~ T.stringof ~ " in order to be a valid argument to remove!");

			return mixin("_foreignKeyField.notEquals(other."
				~ DormField!(RefDB, ModelRef.primaryKeySourceName).sourceColumn ~ ")");
		}
	}

	mixin DynamicMissingMemberErrorHelper!(
		"foreign condition field",
		"`ForeignModelConditionBuilderField` on " ~ RefDB.stringof ~ "." ~ field.sourceColumn
	);
}

/// Helper type to access sub-fields through `ModelRef` foreign key fields. Will
/// join the foreign model table automatically if using any fields on there,
/// other than the primary key, which can be read directly from the source.
///
/// Just like `OrderBuilder` this automatically mirrors all DORM fields of
/// the _foreign_ table, i.e. the referenced model type.
///
/// This type is returned by the `OrderBuilder`. It does not define any members
/// itself, it only defines all members of the referenced Model to be
/// accessible. When operating on the primary key that is referenced to from the
/// ModelRef foreign key, no join operation will be enforced, as the data is
/// stored entirely in the table with the foreign key.
@mustuse
struct ForeignModelOrderBuilderField(ModelRef, ModelFormat.Field field)
{
	alias RefDB = ModelRef.TModel;

	mixin ForeignJoinHelper;

	static foreach (subfield; DormFields!RefDB)
	{
		static if (__traits(isSame, ModelRef.primaryKeyAlias, mixin("RefDB.", subfield.sourceColumn)))
		{
			mixin("OrderBuilderField!(ModelRef.PrimaryKeyType, field) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property @safe return { return OrderBuilderField!(ModelRef.PrimaryKeyType, field)(srcTableName, `",
				field.columnName, "`); }");
		}
		else static if (subfield.isForeignKey)
		{
			mixin("ForeignModelOrderBuilderField!(ModelRefOf!(RefDB.", subfield.sourceColumn, "), subfield) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property return { string placeholder = ensureJoined(); return typeof(return)(placeholder, builderData); }");
		}
		else
		{
			mixin("OrderBuilderField!(typeof(RefDB.", subfield.sourceColumn, "), subfield) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property @safe return { string placeholder = ensureJoined(); return typeof(return)(placeholder, `",
				subfield.columnName,
				"`); }");
		}
	}

	mixin DynamicMissingMemberErrorHelper!(
		"foreign condition field",
		"`ForeignModelOrderBuilderField` on " ~ RefDB.stringof ~ "." ~ field.sourceColumn
	);
}

/// Internal structure returned by the `PopulateBuilder`, which is passed to
/// user code from the `populate` method on a `SelectOperation`. Internally this
/// works by setting the `include` flag on the internal join info structure that
/// either already exists because of previous condition or ordering operations
/// or generates the join info structure on-demand.
///
/// Do not create this struct manually, only use the `PopulateBuilderField` that
/// is passed to you as parameter through the `populate` function on the
/// `SelectOperation` struct, which is returned by `db.select` or `tx.select`.
struct PopulateRef
{
	/// Internal index inside the JoinInfo array that is stored on the
	/// `SelectBuilder`. Do not modify manually, you should only use the
	/// `populate` function on `SelectOperation` to generate this.
	size_t idx;
}

/// Helper struct
@mustuse
struct PopulateBuilderField(ModelRef, ModelFormat.Field field)
{
	alias RefDB = ModelRef.TModel;

	mixin ForeignJoinHelper;

	/// Explicitly say this field is used
	PopulateRef[] yes()
	{
		return [PopulateRef(ensureJoinedIdx)];
	}

	static foreach (subfield; DormFields!RefDB)
	{
		static if (subfield.isForeignKey)
		{
			mixin("PopulateBuilderField!(ModelRefOf!(RefDB.", subfield.sourceColumn, "), subfield) ",
				subfield.sourceColumn.lastIdentifier,
				"() @property return { string placeholder = ensureJoined(); return typeof(return)(placeholder, builderData); }");
		}
	}

	mixin DisallowOperators!(
		"`PopulateBuilderField` on " ~ RefDB.stringof ~ "." ~ field.sourceColumn
	);

	mixin DynamicMissingMemberErrorHelper!(
		"populate field",
		"`PopulateBuilderField` on " ~ RefDB.stringof ~ "." ~ field.sourceColumn
	);
}

/// Returns `"baz"` from `"foo.bar.baz"` (identifier after last .)
/// Returns `s` as-is if it doesn't contain any dots.
private string lastIdentifier(string s)
{
	foreach_reverse (i, c; s)
		if (c == '.')
			return s[i + 1 .. $];
	return s;
}

/// Type that actually implements the condition building on a
/// `ConditionBuilder`.
///
/// Implements building simple unary, binary and ternary operators:
/// - `equals`
/// - `notEquals`
/// - `isTrue` (only defined on boolean types)
/// - `lessThan`
/// - `lessThanOrEqual`
/// - `greaterThan`
/// - `greaterThanOrEqual`
/// - `like`
/// - `notLike`
/// - `regexp`
/// - `notRegexp`
/// - `in_`
/// - `notIn`
/// - `isNull`
/// - `isNotNull`
/// - `exists`
/// - `notExists`
/// - `between`
/// - `notBetween`
@mustuse
struct ConditionBuilderField(T, ModelFormat.Field field)
{
	// TODO: all the type specific field to Condition thingies

	private string tableName;
	private string columnName;

	/// Constructs this ConditionBuilderField with the given columnName for generated conditions.
	this(string tableName, string columnName) @safe
	{
		this.tableName = tableName;
		this.columnName = columnName;
	}

	private Condition* lhs() @safe
	{
		return makeColumnReference(tableName, columnName);
	}

	/// Returns: SQL condition `field == value`
	Condition equals(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.Equals, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field != value`
	Condition notEquals(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.NotEquals, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field == value[0] OR field == value[1] OR ... OR field == value[$ - 1]`
	Condition among(Range)(Range values) @safe
	{
		Condition[] conditions;
		static if (__traits(hasMember, values, "length"))
		{
			conditions.length = values.length;
			size_t i = -1;
			foreach (value; values)
				(() @trusted => conditions[++i] = equals(value))();
		}
		else
		{
			foreach (i, value; values)
				conditions ~= equals(value);
		}

		return Condition.or(conditions);
	}

	static if (field.type == ModelFormat.Field.DBType.boolean)
	{
		/// Returns: SQL condition `field == true`
		Condition isTrue() @safe
		{
			return equals(true);
		}
	}

	/// Returns: SQL condition `field < value`
	Condition lessThan(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.Less, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field <= value`
	Condition lessThanOrEqual(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.LessOrEquals, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field > value`
	Condition greaterThan(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.Greater, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field >= value`
	Condition greaterThanOrEqual(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.GreaterOrEquals, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field LIKE value`
	Condition like(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.Like, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field NOT LIKE value`
	Condition notLike(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.NotLike, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field REGEXP value`
	Condition regexp(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.Regexp, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field NOT REGEXP value`
	Condition notRegexp(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.NotRegexp, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field IN value`
	Condition in_(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.In, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field NOT IN value`
	Condition notIn(V)(V value) @safe
	{
		return Condition(BinaryCondition(BinaryConditionType.NotIn, lhs, makeConditionConstant!field(value)));
	}

	/// Returns: SQL condition `field IS NULL`
	Condition isNull() @safe
	{
		return Condition(UnaryCondition(UnaryConditionType.IsNull, lhs));
	}

	alias equalsNull = isNull;

	/// Returns: SQL condition `field IS NOT NULL`
	Condition isNotNull() @safe
	{
		return Condition(UnaryCondition(UnaryConditionType.IsNotNull, lhs));
	}

	alias notEqualsNull = isNotNull;

	/// Returns: SQL condition `field EXISTS`
	Condition exists() @safe
	{
		return Condition(UnaryCondition(UnaryConditionType.Exists, lhs));
	}

	/// Returns: SQL condition `field NOT EXISTS`
	Condition notExists() @safe
	{
		return Condition(UnaryCondition(UnaryConditionType.NotExists, lhs));
	}

	/// Returns: SQL condition `field BETWEEN min AND max`
	Condition between(L, R)(L min, R max) @safe
	{
		return Condition(TernaryCondition(
			TernaryConditionType.Between,
			lhs,
			makeConditionConstant!field(min),
			makeConditionConstant!field(max)
		));
	}

	/// Returns: SQL condition `field NOT BETWEEN min AND max`
	Condition notBetween(L, R)(L min, R max) @safe
	{
		return Condition(TernaryCondition(
			TernaryConditionType.NotBetween,
			lhs,
			makeConditionConstant!field(min),
			makeConditionConstant!field(max)
		));
	}

	mixin DisallowOperators!(
		"`ConditionBuilderField!(" ~ T.stringof ~ ")` on " ~ field.sourceColumn
	);

	mixin DynamicMissingMemberErrorHelper!(
		"field comparision operator",
		"`ConditionBuilderField!(" ~ T.stringof ~ ")` on " ~ field.sourceColumn
	);
}

/// Type that actually implements the asc/desc methods inside the orderBy
/// callback. (`OrderBuilder`) Defaults to ascending.
struct OrderBuilderField(T, ModelFormat.Field field)
{
	private string tableName;
	private string columnName;

	/// Constructs this OrderBuilderField with the given columnName for generated orders.
	this(string tableName, string columnName) @safe
	{
		this.tableName = tableName;
		this.columnName = columnName;
	}

	/// Ascending ordering.
	ffi.FFIOrderByEntry asc() @safe
	{
		return ffi.FFIOrderByEntry(ffi.FFIOrdering.asc, ffi.ffi(tableName), ffi.ffi(columnName));
	}

	/// Descending ordering.
	ffi.FFIOrderByEntry desc() @safe
	{
		return ffi.FFIOrderByEntry(ffi.FFIOrdering.desc, ffi.ffi(tableName), ffi.ffi(columnName));
	}

	mixin DisallowOperators!(
		"`OrderBuilderField!(" ~ T.stringof ~ ")` on " ~ field.sourceColumn
	);

	mixin DynamicMissingMemberErrorHelper!(
		"field ordering",
		"`OrderBuilderField!(" ~ T.stringof ~ ")` on " ~ field.sourceColumn
	);
}

private struct JoinInformation
{
	private static immutable joinAliasList = {
		// list of _0, _1, _2, _3, ... embedded into the executable
		string[] aliasList;
		foreach (i; 0 .. maxJoins)
			aliasList ~= ("_" ~ i.to!string);
		return aliasList;
	}();

	static struct JoinSuppl
	{
		string placeholder;
		bool include;
	}

	private ffi.FFIJoin[] joins;
	/// Supplemental information for joins, same length and order as in joins.
	private JoinSuppl[] joinSuppl;
	/// Lookup foreign key name -> array index
	private size_t[string] joinedTables;
}

/**
 * This is the builder struct that's used for update operations.
 *
 * Don't construct this struct manually, use the db.update or tx.update method
 * to create this struct.
 *
 * Methods you can call on this builder to manipulate the result:
 * - `condition` to limit which rows to update. (can only be called once)
 * - `set!("sourceColumnName")(value)` to update a single column to the given
 *   value
 * - `set(patchValue)`, where patchValue is a patch for this UpdateOperation, to
 *   set multiple fields at once.
 *
 * Finishing methods you can call on this builder:
 * - `await` to send the prepared update operation
 */
@mustuse
struct UpdateOperation(
	T : Model,
	bool hasWhere = false,
	bool hasAnySet = false,
	bool runtimeCheck = false,
)
{
@safe:
	alias ThisWithWhere = UpdateOperation!(T, true, hasAnySet, runtimeCheck);
	alias ThisWithSet = UpdateOperation!(T, hasWhere, true, runtimeCheck);
	alias ThisWithSetAndRuntimeCheck = UpdateOperation!(T, hasWhere, true, true);

	private const(DormDB)* db;
	private ffi.DBTransactionHandle tx;
	private ffi.FFICondition[] conditionTree;
	private JoinInformation joinInformation;
	private ffi.FFIUpdate[] updates;

	// TODO: might be copyable
	@disable this(this);

	static if (!hasWhere)
	{
		/// Argument to `condition`. Callback that takes in a
		/// `ConditionBuilder!T` and returns a `Condition` that can easily be
		/// created using that builder.
		alias ConditionBuilderCallback = Condition delegate(ConditionBuilder!T);

		/// Limits the update to only rows matching this condition. Maps to the
		/// `WHERE` clause in an SQL statement.
		///
		/// This method may only be called once on each query.
		///
		/// See `ConditionBuilder` to see how the callback-based overload is
		/// implemented. Basically the argument that is passed to the callback
		/// is a virtual type that mirrors all the DB-related types from the
		/// Model class, on which operations such as `.equals` or `.like` can
		/// be called to generate conditions.
		///
		/// Use the `Condition.and(...)`, `Condition.or(...)` or `Condition.not(...)`
		/// methods to combine conditions into more complex ones. You can also
		/// choose to not use the builder object at all and integrate manually
		/// constructed
		ThisWithWhere condition(
			scope ConditionBuilderCallback callback
		) return scope @trusted
		{
			scope ConditionBuilderData data;
			scope ConditionBuilder!T builder;
			builder.builderData = &data;
			data.joinInformation = move(joinInformation);
			conditionTree = callback(builder).makeTree;
			joinInformation = move(data.joinInformation);
			return cast(typeof(return))move(this);
		}
	}

	/// Method to set one field or multiple via a patch. Update will be
	/// performed when `await` is called.
	template set(FieldOrPatch...)
	{
		static if (FieldOrPatch.length == 0)
		{
			ThisWithSet set(P)(P patch) return scope @trusted
			{
				setPatch(patch);
				return cast(typeof(return))move(this);
			}
		}
		else
		{
			static assert(FieldOrPatch.length == 1,
				"Allowed template types on `update.set!(...)` are:\n"
				~ "\t- `set!(\"fieldName\")(value)`\n"
				~ "\t- `set(SomePatch(...))`");

			static if (is(FieldOrPatch[0] == struct))
			{
				ThisWithSet set(FieldOrPatch[0] patch) return scope @trusted
				{
					setPatch(patch);
					return cast(typeof(return))move(this);
				}
			}
			else
			{
				static assert(hasDormField!(T, FieldOrPatch[0]),
					"Called update.set with field `" ~ FieldOrPatch[0]
					~ "`, but it doesn't exist on Model `"
					~ T.stringof ~ "`\n\tAvailable fields:" ~ DormListFieldsForError!T);

				enum field = DormField!(T, FieldOrPatch[0]);

				ThisWithSet set(typeof(mixin("T.", FieldOrPatch[0])) value) return scope @trusted
				{
					static immutable columnName = field.columnName;
					updates ~= ffi.FFIUpdate(
						ffi.ffi(columnName),
						conditionValue!field(value)
					);
					return cast(typeof(return))move(this);
				}

				static if (field.isForeignKey)
				{
					alias ModelRef = ModelRefOf!(mixin("T.", FieldOrPatch[0]));

					ThisWithSet set(ModelRef.PrimaryKeyType value) return scope @trusted
					{
						static immutable columnName = field.columnName;
						updates ~= ffi.FFIUpdate(
							ffi.ffi(columnName),
							conditionValue!field(value)
						);
						return cast(typeof(return))move(this);
					}

					ThisWithSet set(ModelRef.TSelect value) return scope @trusted
					{
						static immutable columnName = field.columnName;
						updates ~= ffi.FFIUpdate(
							ffi.ffi(columnName),
							conditionValue!field(mixin("value.", ModelRef.primaryKeySourceName))
						);
						return cast(typeof(return))move(this);
					}

					static if (!is(ModelRef.TSelect == ModelRef.TModel))
					{
						ThisWithSet set(ModelRef.TModel value) return scope @trusted
						{
							static immutable columnName = field.columnName;
							updates ~= ffi.FFIUpdate(
								ffi.ffi(columnName),
								conditionValue!field(mixin("value.", ModelRef.primaryKeySourceName))
							);
							return cast(typeof(return))move(this);
						}
					}
				}
			}
		}
	}

	private void setPatch(TPatch)(TPatch patch) scope @safe
	if (isSomePatch!TPatch)
	{
		mixin ValidatePatch!(TPatch, T);

		import std.array;

		enum fields = FilterLayoutFields!(T, TPatch);

		static assert(fields.length > 0, "Could not find any fields to set in patch! "
			~ "Model: " ~ T.stringof ~ ", Patch: " ~ TPatch.stringof);

		static foreach (i, field; fields)
		{{
			updates ~= ffi.FFIUpdate(
				ffi.ffi(field.columnName),
				conditionValue!field(
					mixin("patch.", field.sourceColumn)
				)
			);
		}}
	}

	/**
	 * Allows calling `.await()` even if no `set` methods have been called. If
	 * `await` is called without any `set` calls, a `DormUsageException` is
	 * thrown at runtime in that method.
	 */
	ThisWithSetAndRuntimeCheck throwOnNoUpdates() return scope @trusted
	{
		return cast(ThisWithSetAndRuntimeCheck)move(this);
	}

	/**
	 * Starts the update procedure and waits for the result. Throws in case of
	 * an error. Returns the number of rows affected.
	 *
	 * Uses the state modified by previous calls to the builder methods like
	 * `set` and `condition` on this builder object.
	 *
	 * Only callable if either `set` has been called
	 *
	 * Throws: `DormUsageException` if `throwOnNoUpdates` has been and no `set`
	 * calls have been made. Otherwise may throw `DormException` inherited
	 * exceptions if there are DB issues.
	 *
	 * Bugs: currently does not support joins because the underlying library
	 * doesn't expose them yet.
	 */
	static if (hasAnySet)
	{
	ulong await() scope
	{
		// TODO: use join information

			static if (runtimeCheck)
			{
				if (!updates.length)
					throw new DormUsageException("Tried to call `update` without any set columns");
			}
			else
			{
				assert(updates.length, "Expected DB updates here, but didn't have any, "
					~ "even though CT information should have avoided this case!");
			}

		return (() @trusted {
			auto ctx = FreeableAsyncResult!ulong.make;
			ffi.rorm_db_update(
				db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				ffi.ffi(updates),
				conditionTree.length ? &conditionTree[0] : null,
				ctx.callback.expand
			);
			return ctx.result;
		})();
	}
}
	else
	{
		/// ditto
		ulong await()() scope
		{
			static assert(false, "Tried to call `.update.await` without any `.set` calls. If you "
				~ "conditionally set fields at runtime, operate on the builder after `update.throwOnNoUpdates`");
		}
	}
}

/**
 * This is the builder struct that's used for delete operations.
 *
 * Don't construct this struct manually, use the db.remove or tx.remove method
 * to create this struct.
 *
 * Finishing methods you can call on this builder:
 * - `byCondition` to delete all rows matching the condition.
 * - `single` to delete a single instance or patch, matched by primary key.
 * - `bulk` to delete multiple instances or patches in bulk, matched by primary
 *   key.
 * - `all` to delete all rows in the table.
 */
@mustuse
struct RemoveOperation(T : Model)
{
@safe:
	private const(DormDB)* db;
	private ffi.DBTransactionHandle tx;

	// TODO: might be copyable
	@disable this(this);

	/// Argument to `condition`. Callback that takes in a
	/// `ConditionBuilder!T` and returns a `Condition` that can easily be
	/// created using that builder.
	alias ConditionBuilderCallback = Condition delegate(ConditionBuilder!T);

	/**
	 * Deletes the rows matching this condition. Maps to the `WHERE` clause in
	 * an SQL statement.
	 *
	 * See `ConditionBuilder` to see how the callback-based overload is
	 * implemented. Basically the argument that is passed to the callback
	 * is a virtual type that mirrors all the DB-related types from the
	 * Model class, on which operations such as `.equals` or `.like` can
	 * be called to generate conditions.
	 *
	 * Use the `Condition.and(...)`, `Condition.or(...)` or `Condition.not(...)`
	 * methods to combine conditions into more complex ones. You can also
	 * choose to not use the builder object at all and integrate manually
	 * constructed.
	 *
	 * Returns: DB-returned number of how many rows have been touched. May also
	 * include foreign rows deleted by referential actions and other things.
	 *
	 * Bugs: currently does not support joins because the underlying library
	 * doesn't expose them yet.
	 */
	ulong byCondition(
		scope ConditionBuilderCallback callback
	) return scope @trusted
	{
		scope ConditionBuilderData data;
		scope ConditionBuilder!T builder;
		builder.builderData = &data;
		auto conditionTree = callback(builder).makeTree;
		auto joinInformation = move(data.joinInformation);

		// TODO: use join information

		return (() @trusted {
			auto ctx = FreeableAsyncResult!ulong.make;
			ffi.rorm_db_delete(
				db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				&conditionTree[0],
				ctx.callback.expand
			);
			return ctx.result;
		})();
	}

	/**
	 * Deletes the passed-in value by limiting the delete operation to the
	 * primary key of this instance.
	 *
	 * Returns: true if anything was deleted, false otherwise.
	 */
	bool single(T value) scope @safe
	{
		return singleImpl(conditionValue!(DormPrimaryKey!T)(
			mixin("value.", DormPrimaryKey!T.sourceColumn)));
	}

	/// ditto
	bool single(P)(P patch) scope @safe
	if (!is(P == T) && isSomePatch!P)
	{
		mixin ValidatePatch!(P, T);

		static assert(is(typeof(mixin("patch.", DormPrimaryKey!T.sourceColumn))),
			"Primary key '" ~ DormPrimaryKey!T.sourceColumn
			~ "' must be included in patch type "
			~ P.stringof ~ " in order to be a valid argument to remove!");

		return singleImpl(conditionValue!(DormPrimaryKey!T)(
			mixin("patch.", DormPrimaryKey!T.sourceColumn)));
	}

	private bool singleImpl(ffi.FFIValue primaryKey) scope @trusted
	{
		ffi.FFICondition condition, lhs, rhs;
		condition.type = ffi.FFICondition.Type.BinaryCondition;
		condition.binaryCondition.type = ffi.FFIBinaryCondition.Type.Equals;
		condition.binaryCondition.lhs = &lhs;
		condition.binaryCondition.rhs = &rhs;

		lhs.type = ffi.FFICondition.Type.Value;
		rhs.type = ffi.FFICondition.Type.Value;
		lhs.value = columnValue(DormLayout!T.tableName, DormPrimaryKey!T.columnName);
		rhs.value = primaryKey;

		auto ctx = FreeableAsyncResult!ulong.make;
		ffi.rorm_db_delete(
			db.handle,
			tx,
			ffi.ffi(DormLayout!T.tableName),
			&condition,
			ctx.callback.expand
		);
		return ctx.result != 0;
	}

	/**
	 * Deletes the passed-in values by limiting the delete operation to the
	 * primary key of this instance.
	 *
	 * Returns: DB-returned number of how many rows have been touched. May also
	 * include foreign rows deleted by referential actions and other things.
	 */
	ulong bulk(T[] values...) scope @trusted
	{
		ffi.FFICondition[] condition, rhs;
		condition.length = values.length;
		rhs.length = values.length;
		ffi.FFICondition lhs;
		lhs.type = ffi.FFICondition.Type.Value;
		lhs.value = columnValue(DormLayout!T.tableName, DormPrimaryKey!T.columnName);

		foreach (i, value; values)
		{
			condition[i].type = ffi.FFICondition.Type.BinaryCondition;
			condition[i].binaryCondition.type = ffi.FFIBinaryCondition.Type.Equals;
			condition[i].binaryCondition.lhs = &lhs;
			condition[i].binaryCondition.rhs = &rhs[i];

			rhs[i].type = ffi.FFICondition.Type.Value;
			rhs[i].value = conditionValue!(DormPrimaryKey!T)(
				mixin("value.", DormPrimaryKey!T.sourceColumn));
		}

		ffi.FFICondition finalCondition;
		finalCondition.type = ffi.FFICondition.Type.Disjunction;
		finalCondition.disjunction = ffi.ffi(condition);

		auto ctx = FreeableAsyncResult!ulong.make;
		ffi.rorm_db_delete(
			db.handle,
			tx,
			ffi.ffi(DormLayout!T.tableName),
			&finalCondition,
			ctx.callback.expand
		);
		return ctx.result;
	}

	/** 
	 * Deletes all entries in this model.
	 *
	 * Returns: DB-returned number of how many rows have been touched. May also
	 * include foreign rows deleted by referential actions and other things.
	 */
	ulong all() scope @trusted
	{
		auto ctx = FreeableAsyncResult!ulong.make;
		ffi.rorm_db_delete(
			db.handle,
			tx,
			ffi.ffi(DormLayout!T.tableName),
			null,
			ctx.callback.expand
		);
		return ctx.result;
	}
}

/**
 * This is the builder struct that's used for select operations (queries)
 *
 * Don't construct this struct manually, use the db.select or tx.select method
 * (UFCS method defined globally) to create this struct.
 *
 * Methods you can call on this builder to manipulate the result:
 *
 * The following methods are implemented for restricting queries: (most can
 * only be called once, which is enforced through the template parameters)
 * - `condition` is used to set the "WHERE" clause in SQL. It can only be
 *   called once on any query operation.
 * - `limit` can be used to set a maximum number of rows to return. When this
 *   restriction is called, `findOne` and `findOptional` can no longer be used.
 * - `offset` can be used to offset after how many rows to start returning.
 * - `orderBy` can be used to order how the results are to be returned by the
 *   database.
 *
 * The following methods are important when working with `ModelRef` / foreign
 * keys:
 * - `populate` eagerly loads data from a foreign model, (re)using a join
 *
 * Finishing methods you can call on this builder:
 *
 * The following methods can be used to extract the data:
 * - `stream` to asynchronously stream data. (can be used as iterator / range)
 * - `array` to eagerly fetch all data and do a big memory allocation to store
 *   all the values into.
 * - `findOne` to find the first matching item or throw for no data.
 * - `findOptional` to find the first matching item or return Nullable!T.init
 *   for no data.
 *
 * There are restrictions when `stream`/`array` as well as when
 * `findOne`/`findOptional` can be used:
 *
 * `stream`/`array` are usable when:
 * - neither `limit` and `offset` are set
 * - both `limit` and `offset` are set
 * - only `limit` is set and `offset` is not set
 *
 * `findOne`/`findOptional` are only usable when no `limit` is set.
 */
@mustuse
struct SelectOperation(
	T,
	TSelect,
	bool hasWhere = false,
	bool hasOffset = false,
	bool hasLimit = false,
)
{
@safe:
	private const(DormDB)* db;
	private const(ffi.DBTransactionHandle) tx;
	private ffi.FFICondition[] conditionTree;
	private ffi.FFIOrderByEntry[] ordering;
	private JoinInformation joinInformation;
	private ulong _offset, _limit;

	private this(return const(DormDB)* db, return const(ffi.DBTransactionHandle) tx)
	{
		this.db = db;
		this.tx = tx;
	}

	// TODO: might be copyable
	@disable this(this);

	static if (!hasWhere)
	{
		/// Argument to `condition`. Callback that takes in a
		/// `ConditionBuilder!T` and returns a `Condition` that can easily be
		/// created using that builder.
		alias ConditionBuilderCallback = Condition delegate(ConditionBuilder!T);

		/// Limits the query to only rows matching this condition. Maps to the
		/// `WHERE` clause in an SQL statement.
		///
		/// This method may only be called once on each query.
		///
		/// See `ConditionBuilder` to see how the callback-based overload is
		/// implemented. Basically the argument that is passed to the callback
		/// is a virtual type that mirrors all the DB-related types from the
		/// Model class, on which operations such as `.equals` or `.like` can
		/// be called to generate conditions.
		///
		/// Use the `Condition.and(...)`, `Condition.or(...)` or `Condition.not(...)`
		/// methods to combine conditions into more complex ones. You can also
		/// choose to not use the builder object at all and integrate manually
		/// constructed
		SelectOperation!(T, TSelect, true, hasOffset, hasLimit) condition(
			scope ConditionBuilderCallback callback
		) return scope @trusted
		{
			scope ConditionBuilderData data;
			scope ConditionBuilder!T builder;
			builder.builderData = &data;
			data.joinInformation = move(joinInformation);
			conditionTree = callback(builder).makeTree;
			joinInformation = move(data.joinInformation);
			return cast(typeof(return))move(this);
		}
	}

	/// Argument to `orderBy`. Callback that takes in an `OrderBuilder!T` and
	/// returns the ffi ordering value that can be easily created using the
	/// builder.
	alias OrderBuilderCallback = ffi.FFIOrderByEntry delegate(OrderBuilder!T);

	/// Allows ordering by the specified field with the specified direction.
	/// (defaults to ascending)
	///
	/// Returning `u => u.none` means no ordering will be added. (Useful only
	/// at runtime)
	///
	/// Multiple `orderBy` can be added to the same query object. Ordering is
	/// important - the first order orders all the rows, the second order only
	/// orders each group of rows where the previous order had the same values,
	/// etc.
	typeof(this) orderBy(scope OrderBuilderCallback callback) return scope @trusted
	{
		scope ConditionBuilderData data;
		scope OrderBuilder!T builder;
		builder.builderData = &data;
		data.joinInformation = move(joinInformation);
		auto order = callback(builder);
		if (order !is typeof(order).init)
			ordering ~= order;
		joinInformation = move(data.joinInformation);
		return move(this);
	}

	/// Argument to `populate`. Callback that takes in an `OrderBuilder!T` and
	/// returns the ffi ordering value that can be easily created using the
	/// builder.
	alias PopulateBuilderCallback = PopulateRef[] delegate(PopulateBuilder!T);

	/// Eagerly loads the data for the specified foreign key ModelRef fields
	/// when executing the query.
	///
	/// Returning `u => null` means no further populate will be added. (Useful
	/// only at runtime)
	typeof(this) populate(scope PopulateBuilderCallback callback) return scope @trusted
	{
		scope ConditionBuilderData data;
		scope PopulateBuilder!T builder;
		builder.builderData = &data;
		data.joinInformation = move(joinInformation);
		foreach (populates; callback(builder))
			data.joinInformation.joinSuppl[populates.idx].include = true;
		joinInformation = move(data.joinInformation);
		return move(this);
	}

	static if (!hasOffset)
	{
		/// Sets the offset. (number of rows after which to return from the database)
		SelectOperation!(T, TSelect, hasWhere, true, hasLimit) offset(ulong offset) return scope @trusted
		{
			_offset = offset;
			return cast(typeof(return))move(this);
		}
	}

	static if (!hasLimit)
	{
		/// Sets the maximum number of rows to return. Using this method
		/// disables the `findOne` and `findOptional` methods.
		SelectOperation!(T, TSelect, hasWhere, hasOffset, true) limit(ulong limit) return scope @trusted
		{
			_limit = limit;
			return cast(typeof(return))move(this);
		}
	}

	static if (!hasOffset && !hasLimit)
	{
		/// Implementation detail, makes it possible to use `[start .. end]` on
		/// the select struct to set both offset and limit at the same time.
		///
		/// Start is inclusive, end is exclusive - mimicking how array slicing
		/// works.
		ulong[2] opSlice(size_t dim)(ulong start, ulong end)
		{
			return [start, end];
		}

		/// ditto
		SelectOperation!(T, TSelect, hasWhere, true, true) opIndex(ulong[2] slice) return scope @trusted
		{
			this._offset = slice[0];
			this._limit = cast(long)slice[1] - cast(long)slice[0];
			return cast(typeof(return))move(this);
		}

		/// ditto
		SelectOperation!(T, TSelect, hasWhere, true, true) range(ulong start, ulong endExclusive) return scope @safe
		{
			return this[start .. endExclusive];
		}
	}

	private ffi.FFIOption!(ffi.FFILimitClause) ffiLimit() const scope @property @safe
	{
		ffi.FFIOption!(ffi.FFILimitClause) ret;
		static if (hasLimit)
		{
			ret.state = ret.State.some;
			ret.raw_value.limit = _limit;
			static if (hasOffset)
				ret.raw_value.offset = ffi.FFIOption!ulong(_offset);
		}
		return ret;
	}

	static if (hasLimit || !hasOffset)
	{
		/// Fetches all result data into one array. Uses the GC to allocate the
		/// data, so it's not needed to keep track of how long objects live by the
		/// user.
		TSelect[] array() scope @trusted
		{
			auto columns = listDBColumns!(T, TSelect);
			mixin(makeRtColumns);

			TSelect[] ret;
			auto ctx = FreeableAsyncResult!(void delegate(scope ffi.FFIArray!(ffi.DBRowHandle))).make;
			ctx.forward_callback = (scope rows) {
				ret.length = rows.size;
				foreach (i; 0 .. rows.size)
					ret[i] = unwrapRowResult!(T, TSelect)(rows.data[i], joinInformation);
			};
			ffi.rorm_db_query_all(db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				ffi.ffi(rtColumns),
				ffi.ffi(joinInformation.joins),
				conditionTree.length ? &conditionTree[0] : null,
				ffi.ffi(ordering),
				ffiLimit,
				ctx.callback.expand);
			ctx.result();
			return ret;
		}

		/// Fetches all data into a range that can be iterated over or processed
		/// with regular range functions. Does not allocate an array to store the
		/// fetched data in, but may still use sparingly the GC in implementation.
		auto stream() return scope @trusted
		{
			auto columns = listDBColumns!(T, TSelect);
			mixin(makeRtColumns);

			auto stream = sync_call!(ffi.rorm_db_query_stream)(db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				ffi.ffi(rtColumns),
				ffi.ffi(joinInformation.joins),
				conditionTree.length ? &conditionTree[0] : null,
				ffi.ffi(ordering),
				ffiLimit);

			return RormStream!(T, TSelect)(stream, joinInformation);
		}
	}

	static if (!hasLimit)
	{
		/// Returns the first row of the result data or throws if no data exists.
		TSelect findOne() scope @trusted
		{
			auto columns = listDBColumns!(T, TSelect);
			mixin(makeRtColumns);

			TSelect ret;
			auto ctx = FreeableAsyncResult!(void delegate(scope ffi.DBRowHandle)).make;
			ctx.forward_callback = (scope row) {
				ret = unwrapRowResult!(T, TSelect)(row, joinInformation);
			};
			ffi.rorm_db_query_one(db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				ffi.ffi(rtColumns),
				ffi.ffi(joinInformation.joins),
				conditionTree.length ? &conditionTree[0] : null,
				ffi.ffi(ordering),
				ffi.FFIOption!ulong(_offset),
				ctx.callback.expand);
			ctx.result();
			return ret;
		}

		/// Returns the first row of the result data or throws if no data exists.
		Nullable!TSelect findOptional() scope @trusted
		{
			auto columns = listDBColumns!(T, TSelect);
			mixin(makeRtColumns);

			Nullable!TSelect ret;
			auto ctx = FreeableAsyncResult!(void delegate(scope ffi.DBRowHandle)).make;
			ctx.forward_callback = (scope row) {
				if (row)
					ret = unwrapRowResult!(T, TSelect)(row, joinInformation);
			};
			ffi.rorm_db_query_optional(db.handle,
				tx,
				ffi.ffi(DormLayout!T.tableName),
				ffi.ffi(rtColumns),
				ffi.ffi(joinInformation.joins),
				conditionTree.length ? &conditionTree[0] : null,
				ffi.ffi(ordering),
				ffi.FFIOption!ulong(_offset),
				ctx.callback.expand);
			ctx.result();
			return ret;
		}
	}
}

/// Returns: Column[n]
private auto listDBColumns(T, TSelect, Column = ffi.FFIColumnSelector)()
{
	enum fields = FilterLayoutFields!(T, TSelect);

	Column[fields.length] columns;
	static foreach (i, field; fields)
	{{
		enum aliasedName = "__" ~ field.columnName;

		columns[i] = Column(
			ffi.ffi(DormLayout!T.tableName),
			ffi.ffi(field.columnName),
			ffi.ffi(aliasedName)
		);
	}}
	return columns;
}


private enum makeRtColumns = q{
	// inputs: ffi.FFIColumnSelector[n] columns;
	//         JoinInformation joinInformation;
	//         T (template type)
	// output: ffi.FFIColumnSelector[] rtColumns;

	ffi.FFIColumnSelector[] rtColumns = columns[];
	if (joinInformation.joinSuppl.any!"a.include")
	{
		static foreach (fk; DormForeignKeys!T)
		{
			if (auto joinId = fk.columnName in joinInformation.joinedTables)
			{
				auto suppl = joinInformation.joinSuppl[*joinId];
				if (suppl.include)
				{
					auto ffiPlaceholder = ffi.ffi(suppl.placeholder);
					alias RefField = ModelRefOf!(mixin("T.", fk.sourceColumn));
					enum filteredFields = FilterLayoutFields!(RefField.TModel, RefField.TSelect);
					size_t start = rtColumns.length;
					size_t i = 0;
					rtColumns.length += filteredFields.length;
					static foreach (field; filteredFields)
					{{
						auto ffiColumnName = ffi.ffi(field.columnName);
						auto aliasCol = text(suppl.placeholder, ("_" ~ field.columnName));
						rtColumns[start + i].tableName = ffiPlaceholder;
						rtColumns[start + i].columnName = ffiColumnName;
						rtColumns[start + i].selectAlias = ffi.ffi(aliasCol);
						i++;
					}}
				}
			}
		}
	}
};

/// Row streaming range implementation. (query_stream)
@mustuse
private struct RormStream(T, TSelect)
{
	import dorm.lib.util;

	private static struct RowHandleState
	{
		FreeableAsyncResult!(ffi.DBRowHandle) impl;
		alias impl this;
		bool done;

		void reset() @safe
		{
			impl.reset();
			done = false;
		}
	}

	extern(C) private static void rowCallback(
		void* data,
		ffi.DBRowHandle result,
		scope ffi.RormError error
	) nothrow @trusted
	{
		auto res = cast(RowHandleState*)data;
		if (error.tag == ffi.RormError.Tag.NoRowsLeftInStream)
			res.done = true;
		else if (error)
			res.error = error.makeException;
		else
			res.raw_result = result;
		res.awaiter.set();
	}

	private ffi.DBStreamHandle handle;
	private RowHandleState currentHandle;
	private JoinInformation joinInformation;
	private bool started;

	this(return ffi.DBStreamHandle handle, JoinInformation joinInformation = JoinInformation.init) scope @trusted
	{
		this.handle = handle;
		this.joinInformation = joinInformation;
		currentHandle = RowHandleState(FreeableAsyncResult!(ffi.DBRowHandle).make);
	}

	~this() scope @trusted
	{
		if (started)
		{
			currentHandle.impl.waitAndThrow();
			if (currentHandle.impl.raw_result !is null)
				ffi.rorm_row_free(currentHandle.impl.raw_result);
			ffi.rorm_stream_free(handle);
		}
	}

	@disable this(this);

	/// Helper to `foreach` over this entire stream using the row mapped to
	/// `TSelect`.
	int opApply(scope int delegate(TSelect) @system dg) scope @system
	{
		return opApplyImpl(cast(int delegate(TSelect) @safe) dg);
	}
	/// ditto
	int opApply(scope int delegate(TSelect) @safe dg) scope @safe
	{
		return opApplyImpl(dg);
	}
	/// ditto
	int opApplyImpl(scope int delegate(TSelect) @safe dg) scope @safe
	{
		int result = 0;
		for (; !this.empty; this.popFront())
		{
			result = dg(this.front);
			if (result)
				break;
		}
		return result;
	}

	/// Helper to `foreach` over this entire stream using an index (simply
	/// counting up from 0 in D code) and the row mapped to `TSelect`.
	int opApply(scope int delegate(size_t i, TSelect) @system dg) scope @system
	{
		return opApplyImpl(cast(int delegate(size_t i, TSelect) @safe) dg);
	}
	/// ditto
	int opApply(scope int delegate(size_t i, TSelect) @safe dg) scope @safe
	{
		return opApplyImpl(dg);
	}
	/// ditto
	int opApplyImpl(scope int delegate(size_t i, TSelect) @safe dg) scope @safe
	{
		int result = 0;
		size_t i;
		for (; !this.empty; this.popFront())
		{
			result = dg(i++, this.front);
			if (result)
				break;
		}
		return result;
	}

	/// Starts the iteration if it hasn't already, waits until data is there
	/// and returns the current row.
	///
	/// Implements the standard D range interface.
	auto front() scope @trusted
	{
		if (!started) nextIteration();
		return unwrapRowResult!(T, TSelect)(currentHandle.result(), joinInformation);
	}

	/// Starts the iteration if it hasn't already, waits until data is there
	/// and returns if there is any data left to be read using `front`.
	bool empty() scope @trusted
	{
		if (!started) nextIteration();
		currentHandle.impl.waitAndThrow();
		return currentHandle.done;
	}

	/// Starts the iteration if it hasn't already, waits until the current
	/// request is finished and skips the current row, so empty and front can
	/// be called next.
	void popFront() scope @trusted
	{
		if (!started) nextIteration();
		currentHandle.impl.waitAndThrow();
		if (currentHandle.done)
			assert(false, "attempted to run popFront on ended stream");
		else if (currentHandle.impl.error)
			throw currentHandle.impl.error;
		else
		{
			ffi.rorm_row_free(currentHandle.impl.raw_result);
			currentHandle.reset();
			nextIteration();
		}
	}

	private void nextIteration() scope @trusted
	{
		started = true;
		ffi.rorm_stream_get_row(handle, &rowCallback, cast(void*)&currentHandle);
	}

	static assert(isInputRange!RormStream, "implementation error: did not become an input range");
}

/// Extracts the DBRowHandle, optionally using JoinInformation when joins were
/// used, into the TSelect datatype. TSelect may be a DormPatch or the model T
/// directly. This is mostly used internally. Expect changes to this API until
/// there is a stable API.
TSelect unwrapRowResult(T, TSelect)(scope ffi.DBRowHandle row, scope JoinInformation ji) @safe
{
	auto base = unwrapRowResultImpl!(T, TSelect)(row, "__");
	if (ji.joins.length)
	{
		static foreach (fk; DormForeignKeys!T)
		{{
			if (auto idx = fk.columnName in ji.joinedTables)
			{
				auto suppl = ji.joinSuppl[*idx];
				if (suppl.include)
				{
					auto prefix = suppl.placeholder;
					alias ModelRef = ModelRefOf!(mixin("T.", fk.sourceColumn));
					mixin("base.", fk.sourceColumn) = ModelRef(
						unwrapRowResult!(ModelRef.TModel, ModelRef.TSelect)(row, prefix));
				}
			}
		}}
	}
	return base;
}

/// ditto
TSelect unwrapRowResult(T, TSelect)(scope ffi.DBRowHandle row) @safe
{
	return unwrapRowResultImpl!(T, TSelect)(row, null);
}

/// Unwraps the row like the other unwrap methods, but prefixes all fields with
/// `<placeholder>_`, so for example placeholder `foo` and field `user` would
/// result in `foo_user`.
TSelect unwrapRowResult(T, TSelect)(scope ffi.DBRowHandle row, scope const(char)[] placeholder) @safe
{
	scope placeholderDot = new char[placeholder.length + 1];
	placeholderDot[0 .. placeholder.length] = placeholder;
	placeholderDot[$ - 1] = '_'; // was dot before, but that's not valid SQL - we use _ to separate names in aliases!
	return unwrapRowResultImpl!(T, TSelect)(row, placeholderDot);
}

private TSelect unwrapRowResultImpl(T, TSelect)(scope ffi.DBRowHandle row, scope const(char)[] columnPrefix) @safe
{
	TSelect res;
	static if (is(TSelect == class))
		res = new TSelect();
	ffi.RormError rowError;
	enum fields = FilterLayoutFields!(T, TSelect);
	static foreach (field; fields)
	{
		mixin("res." ~ field.sourceColumn) = extractField!(field, typeof(mixin("res." ~ field.sourceColumn)),
			text(" from model ", T.stringof,
				" in column ", field.sourceColumn,
				" in file ", field.definedAt).idup
			)(row, rowError, columnPrefix);
		if (rowError)
			throw rowError.makeException(" (in column '" ~ columnPrefix ~ field.columnName ~ "')");
	}
	return res;
}

private T extractField(alias field, T, string errInfo)(
	scope ffi.DBRowHandle row,
	ref scope ffi.RormError error,
	scope const(char)[] columnPrefix
) @trusted
{
	import std.conv;
	import dorm.declarative;

	scope columnName = ffi.ffi(columnPrefix.length
		? columnPrefix ~ field.columnName
		: field.columnName);

	enum pre = field.isNullable() ? "ffi.rorm_row_get_null_" : "ffi.rorm_row_get_";
	enum suf = "(row, columnName, error)";

	final switch (field.type) with (ModelFormat.Field.DBType)
	{
		case varchar:
			static if (field.type == varchar) return fieldInto!(T, errInfo)(mixin(pre, "str", suf), error);
			else assert(false);
		case varbinary:
			static if (field.type == varbinary) return fieldInto!(T, errInfo)(mixin(pre, "binary", suf), error);
			else assert(false);
		case int8:
			static if (field.type == int8) return fieldInto!(T, errInfo)(mixin(pre, "i16", suf), error);
			else assert(false);
		case int16:
			static if (field.type == int16) return fieldInto!(T, errInfo)(mixin(pre, "i16", suf), error);
			else assert(false);
		case int32:
			static if (field.type == int32) return fieldInto!(T, errInfo)(mixin(pre, "i32", suf), error);
			else assert(false);
		case int64:
			static if (field.type == int64) return fieldInto!(T, errInfo)(mixin(pre, "i64", suf), error);
			else assert(false);
		case floatNumber:
			static if (field.type == floatNumber) return fieldInto!(T, errInfo)(mixin(pre, "f32", suf), error);
			else assert(false);
		case doubleNumber:
			static if (field.type == doubleNumber) return fieldInto!(T, errInfo)(mixin(pre, "f64", suf), error);
			else assert(false);
		case boolean:
			static if (field.type == boolean) return fieldInto!(T, errInfo)(mixin(pre, "bool", suf), error);
			else assert(false);
		case date:
			static if (field.type == date) return fieldInto!(T, errInfo)(mixin(pre, "date", suf), error);
			else assert(false);
		case time:
			static if (field.type == time) return fieldInto!(T, errInfo)(mixin(pre, "time", suf), error);
			else assert(false);
		case datetime:
			static if (field.type == datetime) return fieldInto!(T, errInfo)(mixin(pre, "datetime", suf), error);
			else assert(false);

		static assert(
			field.type != set,
			"field type " ~ field.type.to!string ~ " not yet implemented for reading");

		case choices:
			static if (field.type == choices) return fieldInto!(T, errInfo)(mixin(pre, "str", suf), error);
			else assert(false);
		case set: assert(false);
	}
}

private T fieldInto(T, string errInfo, From)(scope From v, ref scope ffi.RormError error) @safe
{
	import dorm.lib.ffi : FFIArray, FFIOption;
	import std.typecons : Nullable;

	static if (is(T == From))
		return v;
	else static if (is(T == enum))
	{
		auto s = fieldInto!(string, errInfo, From)(v, error);
		static if (is(OriginalType!T == string))
			return cast(T)s;
		else
		{
			switch (s)
			{
				static foreach (f; __traits(allMembers, T))
				{
				case f:
					return __traits(getMember, T, f);
				}
				default:
					error = ffi.RormError(ffi.RormError.Tag.ColumnDecodeError);
					return T.init;
			}
		}
	}
	else static if (is(T == ModelRefImpl!(id, _TModel, _TSelect), alias id, _TModel, _TSelect))
	{
		T ret;
		ret.foreignKey = fieldInto!(typeof(id), errInfo, From)(v, error);
		return ret;
	}
	else static if (is(From == FFIArray!U, U))
	{
		static if (is(T == Res[], Res))
		{
			static if (is(immutable Res == immutable U))
				return (() @trusted => cast(T)v.data.dup)();
			else
				static assert(false, "can't auto-wrap array element type " ~ Res.stringof ~ " into " ~ U.stringof ~ errInfo);
		}
		else static if (is(T == Nullable!V, V))
		{
			return T(fieldInto!(V, errInfo, From)(v, error));
		}
		else
			static assert(false, "can't auto-wrap " ~ U.stringof ~ "[] into " ~ T.stringof ~ errInfo);
	}
	else static if (is(From == FFIOption!U, U))
	{
		static if (is(T == Nullable!V, V))
		{
			if (v.isNull)
				return T.init;
			else
				return T(fieldInto!(V, errInfo)(v.raw_value, error));
		}
		else static if (__traits(compiles, T(null)))
		{
			if (v.isNull)
				return T(null);
			else
				return fieldInto!(T, errInfo)(v.raw_value, error);
		}
		else
		{
			if (v.isNull)
			{
				error = ffi.RormError(ffi.RormError.Tag.ColumnDecodeError);
				return T.init;
			}
			else
			{
				return fieldInto!(T, errInfo)(v.raw_value, error);
			}
		}
	}
	else static if (is(T == Nullable!U, U))
	{
		return T(fieldInto!(U, errInfo, From)(v, error));
	}
	else static if (isIntegral!From)
	{
		static if (isIntegral!T && From.sizeof >= T.sizeof)
		{
			if (v < cast(From)T.min || v > cast(From)T.max)
			{
				error = ffi.RormError(ffi.RormError.Tag.ColumnDecodeError);
				return T.init;
			}
			else
			{
				return cast(T)v;
			}
		}
		else static if (isFloatingPoint!T)
		{
			return cast(T)v;
		}
		else
			static assert(false, "can't put " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
	}
	else static if (isFloatingPoint!From)
	{
		static if (isFloatingPoint!T)
			return cast(T)v;
		else
			static assert(false, "can't put " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
	}
	else static if (is(From : ffi.FFITime))
	{
		static if (is(T == TimeOfDay))
		{
			try
			{
				return TimeOfDay(cast(int)v.hour, cast(int)v.min, cast(int)v.sec);
			}
			catch (DateTimeException)
			{
				error = ffi.RormError(ffi.RormError.Tag.InvalidTimeError);
				return T.init;
			}
		}
		else
			static assert(false, "can't put " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
	}
	else static if (is(From : ffi.FFIDate))
	{
		static if (is(T == Date))
		{
			try
			{
				return Date(cast(int)v.year, cast(int)v.month, cast(int)v.day);
			}
			catch (DateTimeException)
			{
				error = ffi.RormError(ffi.RormError.Tag.InvalidDateError);
				return T.init;
			}
		}
		else
			static assert(false, "can't put " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
	}
	else static if (is(From : ffi.FFIDateTime))
	{
		try
		{
			static if (is(T == DateTime))
			{
				return DateTime(cast(int)v.year, cast(int)v.month, cast(int)v.day,
					cast(int)v.hour, cast(int)v.min, cast(int)v.sec);
			}
			else static if (is(T == SysTime))
			{
				return SysTime(DateTime(cast(int)v.year, cast(int)v.month, cast(int)v.day,
					cast(int)v.hour, cast(int)v.min, cast(int)v.sec), UTC());
			}
			else static if (is(T == long) || is(T == ulong))
			{
				return cast(T)SysTime(DateTime(cast(int)v.year, cast(int)v.month, cast(int)v.day,
					cast(int)v.hour, cast(int)v.min, cast(int)v.sec), UTC()).stdTime;
			}
			else
				static assert(false, "can't put " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
		}
		catch (DateTimeException)
		{
			error = ffi.RormError(ffi.RormError.Tag.InvalidDateTimeError);
			return T.init;
		}
	}
	else
		static assert(false, "did not implement conversion from " ~ From.stringof ~ " into " ~ T.stringof ~ errInfo);
}

/// Sets up the DORM runtime that is required to use DORM (and its
/// implementation library "RORM")
///
/// You must use this mixin to use DORM. You can simply call
/// ```d
/// mixin SetupDormRuntime;
/// ```
/// in your entrypoint file to have the runtime setup automatically.
///
/// Supports passing in a timeout (Duration or integer msecs)
mixin template SetupDormRuntime(alias timeout = 10.seconds)
{
	__gshared bool _initializedDormRuntime;

	shared static this() @trusted
	{
		import dorm.lib.util : sync_call;
		import dorm.lib.ffi : rorm_runtime_start;

		sync_call!(rorm_runtime_start)();
		_initializedDormRuntime = true;
	}

	shared static ~this() @trusted
	{
		import core.time : Duration;
		import dorm.lib.util;
		import dorm.lib.ffi : rorm_runtime_shutdown;

		if (_initializedDormRuntime)
		{
			static if (is(typeof(timeout) == Duration))
				sync_call!(rorm_runtime_shutdown)(timeout.total!"msecs");
			else
				sync_call!(rorm_runtime_shutdown)(timeout);
		}
	}
}
