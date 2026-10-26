#!/bin/bash
# Sourced by build and release scripts; VERSION is the only version authority.
VERSION="$(<"$(dirname "${BASH_SOURCE[0]}")/../VERSION")"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "VERSION must contain a semantic version in X.Y.Z form." >&2
    exit 1
fi
