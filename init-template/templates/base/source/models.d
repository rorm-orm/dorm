/**
	Contains declarative definitions of database models. (maps to SQL tables)
*/
module models;

// imports common things needed in this modelling module. Should not be used
// outside of `module models;` because it adds quite a lot of stuff to the
// global namespace, which might not be useful elsewhere.
import dorm.design;

// Makes it so the models defined in this module can be exported to the
// internal JSON representation that is used by `rorm-cli` / `dub run dorm` to
// automatically create migration files that can be used to initialize the DB.
mixin RegisterModels;

/*
// example model
class User : Model
{
	@Id long id;

	@maxLength(255)
	string username;

	@maxLength(255)
	Nullable!string email;

	@autoCreateTime
	SysTime createdAt;

	@autoUpdateTime
	Nullable!SysTime updatedAt;

	@columnName("admin")
	bool isAdmin;

	@constructValue!(() => Clock.currTime + 24.hours)
	SysTime tempPasswordTime;
}
*/
