/++ dub.sdl:
dependency "requests" version="*"
+/

module update_downloader;

import requests;

import fs = std.file;
import std.algorithm;
import std.array;
import std.digest;
import std.digest.sha;
import std.exception;
import std.json;
import std.process;
import std.stdio;
import std.string;
import std.traits;

enum ArchSuffix
{
	linux_x86,
	osx_x86,
	osx_aarch64,
	windows_x86,
}

void main(string[] args)
{
	auto rq = Request();
	rq.addHeaders(["User-Agent": "[update_downloader.d] https://github.com/rorm-orm/dorm"]);

	auto output = File("download-map.txt", "w");
	output.write("# rorm-cli - ");
	putDownloads(rq, "https://api.github.com/repos/rorm-orm/rorm-cli/releases", output);
	output.writeln();
	output.write("# rorm-lib - ");
	putDownloads(rq, "https://api.github.com/repos/rorm-orm/rorm-lib/releases", output);
}

void putDownloads(ref Request rq, string url, ref File output)
{
	auto rormReleases = rq.get(url).responseBody.toString.parseJSON;

	ArchSuffix[] allSuffixes = [EnumMembers!ArchSuffix];

	ArchSuffix[] missingAssetSuffixes = allSuffixes.dup;

	string[ArchSuffix] downloadURLs;

	auto release = rormReleases.array[0];

	output.writeln(release["tag_name"].str);
	foreach (asset; release["assets"].array)
	{
		string assetName = asset["name"].str;
		string downloadUrl = asset["browser_download_url"].str;
		foreach_reverse (i, missingSuffix; missingAssetSuffixes)
		{
			if (matchesAsset(assetName, missingSuffix))
			{
				downloadURLs[missingSuffix] = downloadUrl;
				missingAssetSuffixes = missingAssetSuffixes.remove(i);
			}
		}
	}

	foreach (suffix; allSuffixes)
	{
		if (auto downloadUrl = suffix in downloadURLs)
		{
			string sigFilePath = "/tmp/verify-test.bin.sig";
			download(rq, *downloadUrl ~ ".sig", sigFilePath);

			string downloadFilePath = "/tmp/verify-test.bin";
			auto downloadFile = File(downloadFilePath, "wb");
			SHA512 sha512;
			sha512.start();
			auto data = rq.get(*downloadUrl).responseBody.data;
			downloadFile.rawWrite(data);
			sha512.put(data);
			downloadFile.close();

			checkSignature(downloadFilePath, sigFilePath);

			output.writeln(suffix, "\t", *downloadUrl, "\t", sha512.finish.toHexString);
		}
		else
		{
			stderr.writeln("Warning: no pre-built release for ", suffix, " - user will be prompted to compile manually!");
		}
	}
}

bool matchesAsset(string asset, ArchSuffix suffix)
{
	final switch (suffix)
	{
		case ArchSuffix.linux_x86:
			return !!asset.endsWith("linux-x86_64.tar.gz");
		case ArchSuffix.osx_x86:
			return !!asset.endsWith("apple-x86_64.tar.gz");
		case ArchSuffix.osx_aarch64:
			return !!asset.endsWith("apple-aarch64.tar.gz");
		case ArchSuffix.windows_x86:
			return !!asset.endsWith("windows-x86_64.zip");
	}
}

void download(ref Request rq, string url, string output)
{
	auto rs = rq.get(url);
	fs.write(output, rs.responseBody.data);
}

void checkSignature(string file, string sigFile)
{
	enforce(spawnProcess([
		"gpg", "--verify", sigFile, file
	]).wait == 0, "Failed to verify " ~ file ~ " with signature " ~ sigFile);
}
