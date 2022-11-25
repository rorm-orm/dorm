# DORM

[![License](https://img.shields.io/github/license/rorm-orm/dorm?label=License)](LICENSE.md)
[![](https://img.shields.io/dub/v/dorm?label=Dub&logo=D)](https://code.dlang.org/packages/dorm)
[![Dub downloads](https://img.shields.io/dub/dw/dorm?label=Downloads)](https://code.dlang.org/packages/dorm)
[![Integration Tests](https://img.shields.io/github/workflow/status/rorm-orm/dorm/Building%20&%20Testing?label=Build)](https://github.com/rorm-orm/dorm/actions/workflows/ci.yml)

A sophisticated D ORM using [rorm-lib](https://github.com/rorm-orm/rorm-lib) as a backend.

Works standalone using multi-threading or with vibe-core.

The following databases are currently supported:
- SQLite 3
- MariaDB 10.5 - 10.9
- Postgres 11 - 15

## Documentation

Take a look at [rorm-orm/docs](https://github.com/rorm-orm/docs) or just use the 
deployed documentation: [rorm.rs](https://rorm.rs).

Auto-generated source code documentation is available on [https://dorm.dpldocs.info/](https://dorm.dpldocs.info/).

## Installation

```
dub add dorm
```

When first compiling, DORM will automatically download pre-compiled library binaries into the package location when it hasn't been downloaded yet. You can also manually put the `librorm.a` (Posix) or `rorm.lib` (Windows) file into the DUB package to not make it download anything.

You can use `dub run dorm` to run the supporting CLI tool, which will be downloaded at the same time. `rorm-cli` is used for creating migrations, which you check-in into your project source and to apply migrations both on development machines as well as on production machines.

## Example

For a more detailed walkthrough see [rorm.rs](https://rorm.rs)

```d
module models;

import dorm.design;

mixin RegisterModels;

class User : Model
{
	@Id long id;

	@maxLength(255)
	string username;

	@maxLength(255)
	string password;

	@autoCreateTime
	SysTime createdAt;

	@columnName("admin")
	bool isAdmin;

	@constructValue!(() => Clock.currTime + 24.hours)
	SysTime tempPasswordTime;
}
```

```d
import models;

import faked, std.datetime.systime, std.random, std.stdio;

import dorm.api.db;

mixin SetupDormRuntime;

void main() {
	@DormPatch!User
	struct UserSelection {
		long id;
		string username;
		SysTime createdAt;
	}

	DBConnectOptions options = {
		backend: DBBackend.SQLite,
		name: "database.sqlite3"
	};
	auto db = DormDB(options);

	auto f = new Faker_de(uniform!int);

	foreach (i; 0 .. 2) {
		@DormPatch!User
		struct UserInsert {
			string username;
			string password;
			bool isAdmin;
		}

		UserInsert user;
		user.username = f.nameName;
		user.password = "123456";
		db.insert(user);
	}

	auto oldestUsers = db.select!UserSelection
		.condition(u => u.not.isAdmin)
		.orderBy(u => u.createdAt.asc)
		.limit(5)
		.stream();

	writeln("Oldest 5 Users:");
	foreach (i, user; oldestUsers) {
		writefln!"#%d %s\tcreated at %s"(i + 1, user.username, user.createdAt);

		// delete first user
		if (i == 0)
			db.remove(user);
	}
}
```

For a more detailed walkthrough see [rorm.rs](https://rorm.rs)

## Contribution

Before contribution, see the [development guidelines](https://rorm.rs/developer/guidelines).
