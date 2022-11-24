// just forwards to rorm-cli, for convenience when running `dub run dorm`

import fs = std.file;
import std.path;
import std.process;
import std.stdio;

int main(string[] args)
{
	version (Windows)
		auto cliPath = buildPath(dirName(args[0]), "rorm-cli.exe");
	else
		auto cliPath = buildPath(dirName(args[0]), "rorm-cli");

	if (fs.exists(cliPath))
		return spawnProcess(cliPath ~ args[1 .. $]).wait;
	else
	{
		try
		{
			return spawnProcess("rorm-cli" ~ args[1 .. $]).wait;
		}
		catch (Exception e)
		{
			writeln("Error: rorm-cli has not been downloaded and is not installed system-wide.");
			writeln("Please install rorm-cli to use this wrapper, you may also call it directly as `dub run dorm` simply forwards to it.");
			writeln();
			writeln("Tried to find auto-downloaded rorm-cli in ", cliPath);
			writeln();
			writeln("To obtain rorm-cli, visit https://github.com/rorm-orm/rorm-cli");
			return 1;
		}
	}
}
