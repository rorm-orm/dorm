import fs = std.file;
import std.algorithm;
import std.array;
import std.process;
import std.stdio;
import std.string;

int main(string[] args)
{
	auto archIndex = args.countUntil("ARCH");
	auto platformIndex = args.countUntil("PLATFORM");

	if (archIndex == -1 || platformIndex == -1)
	{
		stderr.writeln("Usage: ", args[0], " ARCH [archs...] PLATFORM [platforms...]");
		return 1;
	}

	auto platforms = determinePlatforms(args[archIndex + 1 .. platformIndex], args[platformIndex + 1 .. $]);

	if (!platforms.mapNames.length)
	{
		stderr.writeln("The target platform is not yet supported by DORM, ",
			"please open an issue or pull request for the target binary name! (DUB arguments: ",
			args[1 .. $], ")");

		return 1;
	}

	if (fs.exists(platforms.libname))
		return 0; // already downloaded & validated or manually compiled

	try
	{
		downloadTool("rorm-cli", platforms.cliname, platforms, false, "`dub run dorm` will not work properly - download rorm-cli manually!");
		downloadTool("rorm-lib", platforms.libname, platforms, true, "Please manually compile rorm-lib for this platform.");

		return 0;
	}
	catch (Exception e)
	{
		stderr.writeln("Failed to download precompiled rorm binaries: ", e.msg);
		stderr.writeln();
		stderr.writeln("TIP: you can manually compile rorm-lib to skip the automatic download step");
		stderr.writeln("Expected to find or download '", platforms.libname, "' in '", fs.getcwd, "'");
		stderr.writeln("DUB target: ", args[1 .. $]);
		return 1;
	}
}

void downloadTool(string name, string output, TargetPlatform target, bool required, string errorSupplemental = null)
{
	bool inSection = false;
	MapLine[] foundLines;
	foreach (line; File("download-map.txt", "r").byLine)
	{
		if (line.startsWith("# " ~ name))
			inSection = true;
		else if (line.startsWith("#"))
			inSection = false;
		else if (inSection)
		{
			auto mapLine = MapLine.fromString(line.idup);
			if (target.mapNames.canFind(mapLine.platformName))
				foundLines ~= mapLine;
		}
	}

	if (!foundLines.length)
	{
		if (required)
			throw new Exception("Does not have any precompiled binaries for this platform for " ~ name
				~ (errorSupplemental.length ? " - " ~ errorSupplemental : ""));
		else
			stderr.writeln("Warning: Does not have any precompiled binaries for this platform for " ~ name
				~ (errorSupplemental.length ? " - " ~ errorSupplemental : ""));
		return;
	}

	// first mapName takes priority
	foreach (wanted; target.mapNames)
	{
		foreach (found; foundLines)
		{
			if (found.platformName == wanted)
			{
				auto unverifiedOutput = output ~ ".unverified";
				download(found.url, unverifiedOutput);
				validateSHA512(unverifiedOutput, found.sha512);
				fs.rename(unverifiedOutput, output);
				extractAndDelete(output);
				return;
			}
		}
	}

	assert(false);
}

struct MapLine
{
	string platformName;
	string url;
	string sha512;

	static MapLine fromString(string s)
	{
		auto parts = s.split("\t");
		if (parts.length != 3)
			throw new Exception("malformed download-map.txt line: " ~ s);
		return MapLine(parts[0], parts[1], parts[2]);
	}
}

struct TargetPlatform
{
	string[] mapNames, archs, platforms;
	string os;

	static TargetPlatform osx(string[] mapNames, string[] archs, string[] platforms)
	{
		return TargetPlatform(mapNames, archs, platforms, "osx");
	}

	static TargetPlatform linux(string[] mapNames, string[] archs, string[] platforms)
	{
		return TargetPlatform(mapNames, archs, platforms, "linux");
	}

	static TargetPlatform windows(string[] mapNames, string[] archs, string[] platforms)
	{
		return TargetPlatform(mapNames, archs, platforms, "windows");
	}

	string libname() const @property
	{
		if (platforms.canFind("posix"))
			return "librorm.a";
		else if (platforms.canFind("windows"))
			return "rorm.lib";
		else
			throw new Exception("unsupported platform for libname");
	}

	string cliname() const @property
	{
		if (platforms.canFind("posix"))
			return "rorm-cli";
		else if (platforms.canFind("windows"))
			return "rorm-cli.exe";
		else
			throw new Exception("unsupported platform for cliname");
	}
}

TargetPlatform determinePlatforms(string[] archs, string[] platforms)
{
	if (archs.canFind("aarch64"))
	{
		if (platforms.canFind("osx"))
			return TargetPlatform.osx(["osx_arm64", "osx_x86"], archs, platforms);
		else if (platforms.canFind("linux"))
			return TargetPlatform.linux(["linux_arm64"], archs, platforms);
		else
			return TargetPlatform.init;
	}
	else if (archs.canFind("x86_64"))
	{
		if (platforms.canFind("osx"))
			return TargetPlatform.osx(["osx_x86"], archs, platforms);
		else if (platforms.canFind("linux"))
			return TargetPlatform.linux(["linux_x86"], archs, platforms);
		else if (platforms.canFind("windows"))
			return TargetPlatform.windows(["windows_x86"], archs, platforms);
		else
			return TargetPlatform.init;
	}
	else
		return TargetPlatform.init;
}

void download(string url, string file)
{
	auto res = spawnProcess(["wget", url, "-O", file]).wait;
	if (res != 0)
		throw new Exception("Failed to download " ~ url ~ " to " ~ file);
}

void validateSHA512(string file, string sha512)
{
	import std.digest;
	import std.digest.sha;
	import std.string;

	auto got = sha512Of(cast(ubyte[]) fs.read(file));

	if (got.toHexString.toUpper != sha512.toUpper)
		throw new Exception("SHA512 validation failed for file " ~ file);
}

void extractAndDelete(string file)
{
	if (file.endsWith(".tar.gz"))
	{
		if (spawnProcess(["tar", "-xvf", file]).wait != 0)
			throw new Exception("Failed extracting release binary " ~ file);
	}
	else if (file.endsWith(".zip"))
	{
		import std.zip;

		auto zip = new ZipArchive(fs.read(file));

		foreach (name, am; zip.directory)
		{
			zip.expand(am);
			name = name.chompPrefix("/").chompPrefix("\\");
			if (!name.startsWith("."))
				fs.write(name, am.expandedData);
		}
	}
}
