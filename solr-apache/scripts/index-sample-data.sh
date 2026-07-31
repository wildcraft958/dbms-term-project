#!/bin/bash
# index-sample-data.sh - Download Wikipedia dump data and index into Solr

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

BASE_DIR="$SCRIPT_DIR"
DOWNLOADS_DIR="$BASE_DIR/downloads"
CHUNKS_DIR="$DOWNLOADS_DIR/chunks"
SOLR_URL=${SOLR_URL:-http://localhost:8983/solr/searchcore}
SAMPLE_COUNT=${SAMPLE_COUNT:-10000}
CHUNK_SIZE=${CHUNK_SIZE:-500}
FORCE_REGENERATE=${FORCE_REGENERATE:-0}
WIKI_DUMP_URL=${WIKI_DUMP_URL:-https://dumps.wikimedia.org/simplewiki/latest/simplewiki-latest-pages-articles.xml.bz2}
WIKI_DUMP_FILE="$DOWNLOADS_DIR/simplewiki-latest-pages-articles.xml.bz2"
SAMPLE_FILE="$DOWNLOADS_DIR/wikipedia-abstracts-data.json"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command '$1' is not installed."
        exit 1
    fi
}

generate_wikipedia_abstracts_data() {
    if [ ! -f "$WIKI_DUMP_FILE" ]; then
        echo "Downloading public Wikipedia dump..."
        curl -L --fail --retry 3 -o "$WIKI_DUMP_FILE" "$WIKI_DUMP_URL"
    else
        echo "Using existing Wikipedia dump at $WIKI_DUMP_FILE"
    fi

    echo "Transforming Wikipedia pages into Solr documents..."
    python3 - "$WIKI_DUMP_FILE" "$SAMPLE_FILE" "$SAMPLE_COUNT" << 'PY'
import datetime
import bz2
import hashlib
import json
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

dump_path = sys.argv[1]
output_path = sys.argv[2]
max_docs = int(sys.argv[3])

def tag_name(tag):
    return tag.split("}")[-1]

def clean_wikitext(text):
    # Remove comments, refs and templates.
    text = re.sub(r"<!--.*?-->", " ", text, flags=re.DOTALL)
    text = re.sub(r"<ref[^>]*>.*?</ref>", " ", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", text)
    for _ in range(3):
        text = re.sub(r"\{\{[^{}]*\}\}", " ", text)

    # Convert wiki links and external links.
    text = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", text)
    text = re.sub(r"\[\[([^\]]+)\]\]", r"\1", text)
    text = re.sub(r"\[[^\s\]]+\s+([^\]]+)\]", r"\1", text)

    # Remove headings and leftover markup.
    text = re.sub(r"={2,}[^=]+={2,}", " ", text)
    text = text.replace("'''", " ").replace("''", " ")
    text = re.sub(r"\s+", " ", text)
    return text.strip()

def first_paragraph(text):
    for part in re.split(r"\n\s*\n", text):
        p = clean_wikitext(part)
        if p and not p.upper().startswith("#REDIRECT"):
            return p
    return ""

documents = []
timestamp = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

with bz2.open(dump_path, "rb") as fh:
    parser = ET.iterparse(fh, events=("end",))
    for _, elem in parser:
        if tag_name(elem.tag) != "page":
            continue

        title = ""
        namespace = ""
        page_id = ""
        raw_text = ""

        for child in elem:
            child_name = tag_name(child.tag)
            if child_name == "title":
                title = (child.text or "").strip()
            elif child_name == "ns":
                namespace = (child.text or "").strip()
            elif child_name == "id" and not page_id:
                page_id = (child.text or "").strip()
            elif child_name == "revision":
                for rev_child in child:
                    if tag_name(rev_child.tag) == "text":
                        raw_text = (rev_child.text or "")
                        break

        abstract = first_paragraph(raw_text)
        if len(abstract) > 1200:
            abstract = abstract[:1200].rsplit(" ", 1)[0] + "..."

        # Keep only content namespace pages.
        if namespace != "0" or not title or not abstract:
            elem.clear()
            continue

        doc_id = "wiki_" + (page_id if page_id else hashlib.sha1(title.encode("utf-8")).hexdigest()[:16])
        url = "https://simple.wikipedia.org/wiki/" + urllib.parse.quote(title.replace(" ", "_"))

        domain = urllib.parse.urlparse(url).netloc or "wikipedia.org"

        documents.append(
            {
                "id": doc_id,
                "title": title,
                "content": abstract,
                "url": url,
                "domain": domain,
                "author": "Wikipedia",
                "category": ["Public Dataset", "Wikipedia"],
                "tags": ["wikipedia", "public-dataset", "simplewiki"],
                "last_modified": timestamp,
                "file_name": f"{title}.txt",
            }
        )

        elem.clear()

        if len(documents) >= max_docs:
            break

if not documents:
    raise SystemExit("No usable documents found in the Wikipedia dump.")

with open(output_path, "w", encoding="utf-8") as out:
    json.dump(documents, out, ensure_ascii=False)

print(f"Wrote {len(documents)} Wikipedia documents to {output_path}")
PY
}

get_json_count() {
    python3 - "$1" << 'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print(len(data))
PY
}

split_into_chunks() {
    python3 - "$1" "$2" "$3" << 'PY'
import json
import os
import sys

source_file = sys.argv[1]
chunks_dir = sys.argv[2]
chunk_size = int(sys.argv[3])

with open(source_file, "r", encoding="utf-8") as f:
    data = json.load(f)

for index in range(0, len(data), chunk_size):
    chunk_id = index // chunk_size
    out_path = os.path.join(chunks_dir, f"chunk{chunk_id}.json")
    with open(out_path, "w", encoding="utf-8") as out:
        json.dump(data[index:index + chunk_size], out, ensure_ascii=False)
PY
}

require_command curl
require_command python3

mkdir -p "$DOWNLOADS_DIR"

if [ "$FORCE_REGENERATE" = "1" ]; then
    rm -f "$SAMPLE_FILE"
fi

if [ ! -f "$SAMPLE_FILE" ]; then
    generate_wikipedia_abstracts_data
else
    echo "Using existing dataset file at $SAMPLE_FILE"
fi

ACTUAL_COUNT=$(get_json_count "$SAMPLE_FILE")
if [ -z "$ACTUAL_COUNT" ] || [ "$ACTUAL_COUNT" -eq 0 ] 2>/dev/null; then
    echo "Error: dataset file is empty or unreadable: $SAMPLE_FILE"
    exit 1
fi

echo "Checking if Solr is running..."
if ! curl -s "${SOLR_BASE_URL}/" > /dev/null; then
    echo "Error: Solr is not running. Please start Solr using the start-services.sh script."
    exit 1
fi

echo "Checking if '${COLLECTION}' collection exists..."
if ! curl -s "${SOLR_BASE_URL}/admin/collections?action=LIST" | grep -q "${COLLECTION}"; then
    echo "Error: '${COLLECTION}' collection does not exist. Please create it first."
    exit 1
fi

echo "Indexing sample data..."
echo "This may take a while for $ACTUAL_COUNT documents..."

rm -rf "$CHUNKS_DIR"
mkdir -p "$CHUNKS_DIR"
split_into_chunks "$SAMPLE_FILE" "$CHUNKS_DIR" "$CHUNK_SIZE"

TOTAL_CHUNKS=$(((ACTUAL_COUNT + CHUNK_SIZE - 1) / CHUNK_SIZE))
for i in $(seq 0 $((TOTAL_CHUNKS - 1))); do
    echo "Indexing chunk $((i+1))/$TOTAL_CHUNKS..."
    curl --fail -X POST -H "Content-Type: application/json" --data-binary @"$CHUNKS_DIR/chunk$i.json" "$SOLR_URL/update?commit=true" > /dev/null
done

echo "Optimizing the index..."
curl --fail -X POST "$SOLR_URL/update?optimize=true&waitFlush=true" > /dev/null

echo "Indexing complete! Indexed $ACTUAL_COUNT documents from Wikipedia dump."
echo "You can now run the benchmark scripts to test performance."