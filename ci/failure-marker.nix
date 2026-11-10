# Pushed to the cache by Sulu when its build of `rev` fails, so promote.sh can
# report the failure before the build window closes
{rev}: builtins.toFile "helium-build-failed-${rev}" "${rev}\n"
