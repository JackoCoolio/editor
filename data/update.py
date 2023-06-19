#!/usr/bin/env python3

import requests

url = "https://www.unicode.org/Public/UCD/latest/ucd/"

files = ["CaseFolding.txt", "UnicodeData.txt", "emoji/emoji-data.txt"]

def get_full_path(file):
    return url + file

def get_file_name(file: str):
    return file.split("/")[-1]

def strip_blank_lines(s: str):
    return "\n".join([line for line in s.splitlines() if len(line) > 0])

def strip_file(s: str):
    s = strip_blank_lines(s)
    s = add_newline(s)
    return s

def add_newline(s: str):
    if s[-1] == '\n':
        return s
    else:
        return s + "\n"

def download_file(filename):
    path = get_full_path(filename)
    resp = requests.get(path)

    out_filename = get_file_name(filename)
    with open(out_filename, "w+") as file:
        data = resp.content.decode(encoding="utf-8")
        s = strip_file(data)
        file.write(s)

def main():
    for file in files:
        download_file(file)

if __name__ == "__main__":
    main()
