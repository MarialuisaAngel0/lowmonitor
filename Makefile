NASM = nasm
LD   = ld
SRC  = src/lowmonitor.asm
OBJ  = build/lowmonitor.o
BIN  = bin/lowmonitor

all: $(BIN)

$(BIN): $(OBJ)
	@mkdir -p bin
	$(LD) -o $@ $<

$(OBJ): $(SRC)
	@mkdir -p build
	$(NASM) -f elf64 -g -F dwarf -o $@ $<

run: all
	./$(BIN)

clean:
	rm -rf build bin

.PHONY: all run clean