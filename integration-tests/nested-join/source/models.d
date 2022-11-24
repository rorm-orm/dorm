module models;

import dorm.design;

mixin RegisterModels;

class User : Model
{
	@maxLength(255) @primaryKey
	string id;
	@maxLength(255)
	string fullName;
	@maxLength(255)
	string email;
}

class Toot : Model
{
	@Id long id;
	@maxLength(2048)
	string message;
	@autoCreateTime
	SysTime createdAt;
	ModelRef!User author;
}

class Reply : Model
{
	@Id long id;
	ModelRef!Toot replyTo;

	@maxLength(255)
	string message;

	@autoCreateTime
	SysTime createdAt;
}
