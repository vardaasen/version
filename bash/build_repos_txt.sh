#!/usr/bin/env bash
yq 'to_entries | .[] | .key as $category | .value[] | [$category, .] | @csv' repos.yml > repos.txt
