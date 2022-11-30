module dorm.types.relations;

import dorm.declarative.conversion;
import dorm.model;
import dorm.types.patches;

version(none) static struct ManyToManyField(alias idOrModel)
{
	alias T = ModelFromIdOrModel!idOrModel;
	alias primaryKeyAlias = IdAliasFromIdOrModel!idOrModel;
	enum primaryKeyField = IdFieldFromIdOrModel!idOrModel;
	alias PrimaryKeyType = typeof(primaryKeyAlias);

	bool toClear;
	PrimaryKeyType[] toAdd;
	PrimaryKeyType[] toRemove;

	private T[] cached;
	private bool resolved;

	T[] populated()
	{
		assert(resolved, "ManyToManyField reference is not populated! Call "
			~ "`db.populate!(Model.manyToManyFieldName)(modelInstance)` or query "
			~ "data with the recursion flag set!");
		return cached;
	}

	void setCachedPopulated(T[] populated)
	{
		cached = populated;
		resolved = true;
	}

	void add(T other)
	{
		auto refField = __traits(child, other, primaryKeyAlias);
		toRemove = toRemove.remove!(refField);
		toAdd ~= refField;
	}

	void add(PrimaryKeyType primaryKey)
	{
		toRemove = toRemove.remove!(primaryKey);
		toAdd ~= primaryKey;
	}

	void add(Range)(Range range)
	if (!is(Range == T)
	&& !is(Range == PrimaryKeyType))
	{
		foreach (item; range)
			add(item);
	}

	void remove(T other)
	{
		auto refField = __traits(child, other, primaryKeyAlias);
		toAdd = toAdd.remove!(refField);
		toRemove ~= refField;
	}

	void add(PrimaryKeyType primaryKey)
	{
		toRemove = toRemove.remove!(primaryKey);
		toAdd ~= primaryKey;
	}

	void remove(Range)(Range range)
	if (!is(Range == T)
	&& !is(Range == PrimaryKeyType))
	{
		foreach (item; range)
			remove(item);
	}

	void clear()
	{
		toAdd.length = 0;
		toRemove.length = 0;
		toClear = true;
	}
}

/**
 * DORM field type representing a referenced model through a foreign key in SQL.
 *
 * The actual data stored in the DB as foreign key is what's stored in the
 * `foreignKey` member. The `populated` property is simply a cache member for
 * supporting proactively fetched joined data from the database. Trying to
 * access the populated data without having it populated will result in a
 * program crash through `assert(false)`.
 *
 * Bugs: `db.populate(ModelRef)` is not yet implemented
 */
static template ModelRef(alias idOrPatch)
{
	alias primaryKeyAlias = IdAliasFromIdOrPatch!idOrPatch;
	alias TPatch = PatchFromIdOrPatch!idOrPatch;
	alias T = ModelFromSomePatch!TPatch;
	alias ModelRef = ModelRefImpl!(primaryKeyAlias, T, TPatch);
}

/// ditto
static struct ModelRefImpl(alias id, _TModel, _TSelect)
{
	alias TModel = _TModel;
	alias TSelect = _TSelect;
	alias primaryKeyAlias = id;
	enum primaryKeyField = DormField!(_TModel, __traits(identifier, id));
	alias PrimaryKeyType = typeof(primaryKeyAlias);

	/// The actual data stored in the DB field. Can be manipulated manually to
	/// perform special operations not supported otherwise.
	PrimaryKeyType foreignKey;

	private TSelect cached;
	private bool resolved;

	/// Returns: `true` if populated can be called, `false` otherwise.
	bool isPopulated() const @property
	{
		return resolved;
	}

	/**
	 * Returns: the value that was fetched from the database. Only works if the
	 * value was either requested to be included using `select.populate` or by
	 * calling `db.populate(thisObject)`.
	 *
	 * When trying to call this function with an unpopulate object, the program
	 * will crash with an AssertError.
	 */
	TSelect populated()
	{
		if (!resolved)
		{
			assert(false, "ModelRef reference is not populated! Call "
				~ "`db.populate!(Model.referenceFieldName)(modelInstance)` or query "
				~ "data with `select!T.populate(o => o.fieldNameToPopulate.yes)`!");
		}
		return cached;
	}

	/**
	 * Sets the populated value as well as the foreign key for saving in the DB.
	 */
	auto opAssign(TSelect value)
	{
		resolved = true;
		cached = value;
		foreignKey = __traits(child, value, primaryKeyAlias);
		return value;
	}

	/// Returns true if `other`'s primary key is equal to the foreign key stored
	/// in this ModelRef instance. Does not check any other fields. Does not
	/// require this ModelRef to be populated.
	bool refersTo(const TModel other) const
	{
		return foreignKey == mixin("other.", primaryKeyField.sourceColumn);
	}

	static if (!is(TModel == TSelect))
	{
		/// ditto
		bool refersTo(const TSelect other) const
		{
			return foreignKey == __traits(child, other, primaryKeyAlias);
		}
	}
}

// TODO: need to figure out how to make BackRefs
version (none)
static struct BackRef(alias foreignField)
{
	static assert(is(__traits(parent, foreignField) : Model),
		"Invalid foreign key field `" ~ foreignField.stringof
		~ "`! Change to `BackRef!(OtherModel.foreignKeyReferencingThis)`");

	alias T = __traits(parent, foreignField);

	private T[] cached;
	private bool resolved;

	T[] populated()
	{
		assert(resolved, "BackRef value is not populated! Call "
			~ "`db.populate!(Model.otherFieldReferencingThis)(modelInstance)` or query "
			~ "data with the recursion flag set!");
		return cached;
	}
}
