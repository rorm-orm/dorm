#!/usr/bin/env bash
set -euo pipefail

pushd ..
export RORM_CLI="$(pwd)/rorm-cli"
popd

if [ -z "${1:-}" ];
then
	MATCH="*/"
else
	MATCH="$1"
fi

DATABASE_CONFIG=$(cat <<-END
[Database]
Driver = 'SQLite'
Filename = 'test.sqlite3'
END
)

EXIT_CODE=0

for testDir in $MATCH
do
	echo "Running $testDir"
	pushd "$testDir"
	if [ -f "run.sh" ]; then
		rm -rf .dub
		rm -rf migrations
		rm -f .models.json
		rm -f database.sqlite3
		if [ ! -f database.toml ]; then
		  echo "$DATABASE_CONFIG" > database.toml
		fi
		if ! ./run.sh; then
			echo "Error: Test $testDir failed"
			EXIT_CODE=1
		fi
	else
		echo "Error: Missing run.sh in $testDir"
		EXIT_CODE=1
	fi
	popd
done

exit $EXIT_CODE
