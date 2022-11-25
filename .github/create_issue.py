#!/usr/bin/python3

import os
import json
import binascii
import platform

import requests


def main():
    repository = os.environ.pop('GITHUB_REPOSITORY')
    url = f"https://api.github.com/repos/{repository}/issues"
    body = os.environ.get("ISSUE_BODY")
    if body is None:
        if os.environ.get("ISSUE_BODY_FILE") is not None:
            with open(os.environ.get("ISSUE_BODY_FILE")) as f:
                body = f.read()

    if body is None:
        with open("stdout.txt") as f:
            program_stdout = f.read()
        with open("stderr.txt") as f:
            program_stderr = f.read()
        body = f"""{program_stderr}\n```\n\nFurther details:\n```\n{program_stdout}"""
    checksum = hex(binascii.crc32((body + platform.system() + platform.machine()).encode("UTF-8")))[2:]

    run_id = os.environ.pop("GITHUB_RUN_ID")
    run_url = f"https://github.com/{repository}/actions/runs/{run_id}"
    body = f"""A recent GitHub action has discovered a possible future incompatibility with `rorm-lib` or `rorm-cli`!
    The pipeline triggered by the commit {os.environ.pop('GITHUB_SHA')} did not compile with some latest version of the `rorm` libraries or binaries.
    See the action [{run_id}]({run_url}) for more details. The run was performed on `{' '.join(platform.uname())}`.
    Build log details:\n\n```\n{body}\n```\n\nChecksum: `{checksum}`"""

    headers = {
        "Accept": "application/vnd.github.v3+json",
        "Authorization" : f"token {os.environ.pop('GITHUB_TOKEN')}"
    }
    data = {
        "title": f"CI Future Compatibility Warning: {os.environ.pop('ISSUE_TITLE')} ({platform.system()}/{platform.machine()})",
        "body": body,
        "labels": ["ci"]
    }

    existing_issues_response = requests.get(url=url, headers=headers)

    if existing_issues_response.status_code == 200:
        issues = existing_issues_response.json()

        for issue in issues:
            if issue["body"].split("\n")[-1].strip().startswith(f"Checksum: `{checksum}`"):
                print(f"Issue with the same checksum {checksum} already exists on \033[36mhttps://github.com/{repository}\033[0m!")
                return 0

        new_issue_response = requests.post(url=url, json=data, headers=headers)

        if new_issue_response.status_code == 201:
            print(f"Issue successfully created on \033[36mhttps://github.com/{repository}\033[0m!")
            print(json.dumps(new_issue_response.json(), indent=2))
            return 0

        else:
            print(f"Couldn't create new issue on \033[36mhttps://github.com/{repository}\033[0m!")
            print(f"Status code {new_issue_response.status_code} for {url!r}.")
            print(json.dumps(new_issue_response.json(), indent=2))
            return 1

    else:
        print(f"Error: Couldn't check issues on \033[36mhttps://github.com/{repository}\033[0m!")
        print(f"Status code {existing_issues_response.status_code} for {url!r}.")
        print(json.dumps(existing_issues_response.json(), indent=2))
        return 1


if __name__ == "__main__":
    exit(main())
