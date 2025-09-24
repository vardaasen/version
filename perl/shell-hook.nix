# In your shell hook:
shellHook = ''
  echo "★ Development environment loaded!"
  
  # Version comparison report
  if command -v check-versions.pl >/dev/null 2>&1; then
    check-versions.pl --format=nix-report
  fi
  
  echo "☻ Python $(python --version)"
  echo "☻ Deno $(deno --version)"
'';
# Non-emoji pictographic characters
# https://character.construction/picto
