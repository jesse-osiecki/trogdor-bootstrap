#!/bin/sh
# Enroll a new Howdy face model from a terminal window.
# Launched by the "Howdy: add face" desktop entry.

echo "Howdy face enrollment"
echo
echo "Existing models:"
sudo howdy list 2>/dev/null || true
echo
default="model-$(date +%Y%m%d-%H%M)"
printf 'Label for the new model (glasses, evening, ...) [%s]: ' "$default"
read -r label
[ -n "$label" ] || label="$default"
echo
echo "Look at the front camera and hold still..."
echo
if sudo howdy add "$label"; then
	echo
	echo "Done. Models now:"
	sudo howdy list
else
	echo
	echo "Enrollment failed (see above)."
fi
echo
printf 'Press Enter to close. '
read -r _
