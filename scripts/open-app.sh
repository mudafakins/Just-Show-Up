#!/bin/bash
# Opens the built app. Exists so nobody has to type the "!" in its name,
# which zsh treats specially inside double quotes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
open "$ROOT"/build/*.app
