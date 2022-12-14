module models;

import dorm.design;

mixin RegisterModels;

struct AuthInfo {
	@maxLength(32)
	string method = "password";
	@maxLength(255)
	string passwordHash;
	@maxLength(255)
	string token;
	@maxLength(255)
	string secret;
	@maxLength(255)
	string info;
}

class User : Model
{
	@Id long id;

	struct Fields
	{
		@defaultFromInit
		bool active = true;
		@defaultFromInit
		bool banned;
		@maxLength(255) @unique
		string name;
		@maxLength(255)
		string fullName;
		@maxLength(255)
		string email;
		// TODO: 1-n relation for arrays
		// string[] groups;
		@maxLength(20)
		Nullable!string activationCode;
		@maxLength(20)
		Nullable!string resetCode;
		Nullable!SysTime resetCodeExpireTime;
		@embedded
		AuthInfo auth;
		// TODO: 1-n relation to (string, Blob)[]
		// Blob[string] properties;
	}

	@embedded
	Fields fields;
	alias fields this;
}
