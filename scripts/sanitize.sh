#!/usr/bin/env bash

sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

if [ "$#" -eq 1 ]; then
  sanitize "$1"
fi
