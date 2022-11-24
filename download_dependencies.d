import fs = std.file;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.exception;
import std.math;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.traits;

// debug = Verbose;

version (Windows) pragma(lib, "wininet");

__gshared bool color;

int main(string[] args)
{
	version (Posix)
		color = true;

	if (environment.get("NO_COLOR").length)
		color = false;

	auto archIndex = args.countUntil("ARCH");
	auto platformIndex = args.countUntil("PLATFORM");

	if (archIndex == -1 || platformIndex == -1)
	{
		errorln("Usage: ", args[0], " ARCH [archs...] PLATFORM [platforms...]");
		return 1;
	}

	auto platforms = determinePlatforms(args[archIndex + 1 .. platformIndex], args[platformIndex + 1 .. $]);
	auto nativePlatform = TargetPlatform.currentPlatform;

	if (!platforms.mapNames.length)
	{
		errorln("The target platform is not yet supported by DORM, ",
			"please open an issue or pull request for the target binary name! (DUB arguments: ",
			args[1 .. $], ")");

		return 1;
	}

	if (fs.exists(platforms.libname))
		return 0; // already downloaded & validated or manually compiled

	logln("Missing ", platforms.libname.bold, " in dependency ", `"dorm"`.bold, ". Downloading pre-compiled binary from GitHub...");

	try
	{
		if (!fs.exists(nativePlatform.cliname))
		{
			bool hasCLI = downloadTool("rorm-cli", nativePlatform.cliname, nativePlatform, false, "`dub run dorm` will not work properly - download rorm-cli manually!");

			if (!hasCLI)
				supplln("> `dub run dorm` will not invoke the CLI!");
		}

		downloadTool("rorm-lib", platforms.libname, platforms, true, "Please manually compile rorm-lib for this platform.");

		logln("Done! DORM will reuse the rorm-lib binary from now on. Downloaded to: ", buildPath(fs.getcwd, platforms.libname).bold);

		return 0;
	}
	catch (Exception e)
	{
		supplln();
		debug (Verbose)
			errorln("Failed to download precompiled rorm binaries!\n", whitespacePrefix, e.toString);
		else
			errorln("Failed to download precompiled rorm binaries!\n", whitespacePrefix, e.msg);
		supplln("Expected to find or download '", platforms.libname, "' in '", fs.getcwd, "'");
		supplln();
		logln("TIP: you can manually compile rorm-lib to skip the automatic download step");
		supplln("DUB target: ", args[1 .. $].join(", "));
		supplln();
		logln("GitHub: https://github.com/rorm-orm/rorm-lib");
		return 1;
	}
}

bool downloadTool(string name, string output, TargetPlatform target, bool required, string errorSupplemental = null)
{
	bool inSection = false;
	MapLine[] foundLines;
	foreach (line; File("download-map.txt", "r").byLine)
	{
		line = line.strip;
		if (!line.length)
			continue;

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
				~ (errorSupplemental.length ? "\n" ~ whitespacePrefix ~ errorSupplemental : ""));
		else
			errorln("Warning: Does not have any precompiled binaries for this platform for " ~ name
				~ (errorSupplemental.length ? "\n" ~ whitespacePrefix ~ errorSupplemental : ""));
		return false;
	}

	// first mapName takes priority
	foreach (wanted; target.mapNames)
	{
		foreach (found; foundLines)
		{
			if (found.platformName == wanted)
			{
				auto unverifiedOutput = output ~ ".unverified" ~ target.archiveExtension;
				download(found.url, unverifiedOutput);
				validateSHA512(unverifiedOutput, found.sha512);
				fs.rename(unverifiedOutput, output ~ target.archiveExtension);
				extractAndDelete(output ~ target.archiveExtension);
				markExecutable(output);
				foreach (del; target.forbiddenFiles)
					if (fs.exists(del))
						fs.remove(del);
				return true;
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

	static TargetPlatform currentPlatform()
	{
		string[] archs;
		string[] platforms;

		version (AArch64)
			archs ~= "aarch64";
		version (ARM)
			archs ~= "arm";
		version (X86)
			archs ~= "x86";
		version (X86_64)
			archs ~= "x86_64";

		version (Posix)
			platforms ~= "posix";
		version (OSX)
			platforms ~= "osx";
		version (linux)
			platforms ~= "linux";
		version (BSD)
			platforms ~= "bsd";
		version (FreeBSD)
			platforms ~= "freebsd";
		version (OpenBSD)
			platforms ~= "openbsd";
		version (Windows)
			platforms ~= "windows";

		return determinePlatforms(archs, platforms);
	}

	string archiveExtension() const @property
	{
		if (platforms.canFind("posix"))
			return ".tar.gz";
		else if (platforms.canFind("windows"))
			return ".zip";
		else
			throw new Exception("unsupported platform for archiveExtension");
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

	/// Files that are auto-deleted after download if they exist
	string[] forbiddenFiles() const @property
	{
		// list of forbidden files for this platform
		if (platforms.canFind("linux"))
			return ["librorm.so"];
		else if (platforms.canFind("osx"))
			return ["librorm.dylib"];
		else if (platforms.canFind("windows"))
			return ["rorm.dll"];
		else
			throw new Exception("unsupported platform for libname");
	}
}

TargetPlatform determinePlatforms(string[] archs, string[] platforms)
{
	if (archs.canFind("aarch64"))
	{
		if (platforms.canFind("osx"))
			return TargetPlatform.osx(["osx_aarch64", "osx_x86"], archs, platforms);
		else if (platforms.canFind("linux"))
			return TargetPlatform.linux(["linux_aarch64"], archs, platforms);
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
	logln("Downloading DORM dependency from ", url);
	version (Windows)
	{
		File outFile = File(file, "wb");

		StopWatch sw;
		sw.start();

		import core.sys.windows.windows : DWORD;
		import core.sys.windows.wininet : INTERNET_FLAG_NO_UI,
			INTERNET_OPEN_TYPE_PRECONFIG, InternetCloseHandle, InternetOpenA,
			InternetOpenUrlA, InternetReadFile, IRF_NO_WAIT, INTERNET_BUFFERSA,
			HttpQueryInfoA, HTTP_QUERY_CONTENT_LENGTH;

		auto handle = enforce(InternetOpenA("[download_dependencies] https://github.com/rorm-orm/dorm",
				INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0), "Failed to download " ~ url ~ " to " ~ file);
		scope (exit)
			InternetCloseHandle(handle);

		auto obj = enforce(InternetOpenUrlA(handle, cast(const(char)*) url.toStringz,
				null, 0, INTERNET_FLAG_NO_UI, 0), "Failed to download " ~ url ~ " to " ~ file);
		scope (exit)
			InternetCloseHandle(obj);

		scope ubyte[] buffer = new ubyte[50 * 1024];

		long maxLen;
		DWORD contentLengthLength = 16;
		DWORD index = 0;
		if (HttpQueryInfoA(obj, HTTP_QUERY_CONTENT_LENGTH, buffer.ptr, &contentLengthLength, &index))
			maxLen = (cast(char[]) buffer[0 .. contentLengthLength]).strip.to!long;

		long received;
		while (true)
		{
			DWORD read;
			if (!InternetReadFile(obj, buffer.ptr, cast(DWORD) buffer.length, &read))
				throw new Exception("Failed to download " ~ url ~ " to " ~ file);

			if (read == 0)
				break;

			outFile.rawWrite(buffer[0 .. read]);
			received += read;

			if (sw.peek >= 1.seconds)
			{
				sw.reset();
				if (maxLen > 0)
					supplln(format!"%s %s / %s (%.1f %%)"(file, humanSize(received),
							humanSize(maxLen), received / cast(float) maxLen * 100));
				else
					supplln(format!"%s %s / ???"(file, humanSize(received)));
			}
		}
	}
	else
	{
		auto res = spawnProcess(["wget", url, "-q", "--show-progress", "-U", "[download_dependencies] https://github.com/rorm-orm/dorm", "-O", file]).wait;
		if (res != 0)
			throw new Exception("Failed to download " ~ url ~ " to " ~ file);
	}
}

void validateSHA512(string file, string sha512)
{
	import std.digest;
	import std.digest.sha;
	import std.string;

	supplln("\tValidating integrity...");

	auto got = sha512Of(cast(ubyte[]) fs.read(file));

	if (got.toHexString.toUpper != sha512.toUpper)
		throw new Exception("SHA512 validation failed for file " ~ file);
}

void extractAndDelete(string file)
{
	supplln("\tExtracting archive...");

	if (file.endsWith(".tar.gz"))
	{
		if (spawnProcess(["tar", "-xf", file]).wait != 0)
			throw new Exception("Failed extracting release binary " ~ file);
	}
	else if (file.endsWith(".zip"))
	{
		import std.zip;

		scope zip = new ZipArchive(fs.read(file));

		foreach (name, am; zip.directory)
		{
			zip.expand(am);
			name = name.chompPrefix("/").chompPrefix("\\");
			if (!name.startsWith("."))
				fs.write(name, am.expandedData);
		}
	}
	fs.remove(file);
}

void markExecutable(string file)
{
	fs.setAttributes(file, fs.getAttributes(file) | octal!700);
}

private static immutable logPrefix      = " \x1b[35;1mdorm \x1b[0;35mHelper \x1b[m";
private static immutable errorLogPrefix = " \x1b[31;1mdorm \x1b[0;31mHelper \x1b[m";
private static immutable colorlessPrefix  = " dorm Helper ";
private static immutable whitespacePrefix = "             ";

string bold(string s)
{
	if (color)
		return "\x1b[1m" ~ s ~ "\x1b[0m";
	else
		return s;
}

void logln(T...)(T args)
{
	if (color)
		writeln(logPrefix, args);
	else
		writeln(colorlessPrefix, args);
}

void supplln(T...)(T args)
{
	writeln(whitespacePrefix, args);
}

void errorln(T...)(T args)
{
	if (color)
		stderr.writeln(errorLogPrefix, args);
	else
		stderr.writeln(colorlessPrefix, args);
}

string humanSize(T)(T bytes) if (isIntegral!T)
{
	static immutable string prefixes = "kMGTPE";

	if (bytes < 1024)
		return text(bytes, " B");
	int exp = cast(int)(log2(bytes) / 8); // 8 = log2(1024)
	return format!"%.1f %siB"(bytes / cast(float) pow(1024, exp), prefixes[exp - 1]);
}
