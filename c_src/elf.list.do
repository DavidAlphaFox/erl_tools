# Create a list of targets
TARGETS="\
v4l.host.elf \
sqlite3.host.elf \
gdbstub_connect.host.elf \
"
redo-ifchange $TARGETS
echo $TARGETS >$3

