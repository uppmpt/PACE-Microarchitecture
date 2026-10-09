.section .text
.globl _start

_start:
    # Endereço base de resultados: 0x200
    lui   x31, 0x0
    addi  x31, x0, 0x200

    # Test 1: ADD
    addi  x1, x0, 100
    addi  x2, x0, 200
    add   x3, x1, x2        # 300
    sd    x3, 0(x31)

    # Test 2: SUB
    sub   x4, x2, x1        # 100
    sd    x4, 8(x31)

    # Test 3: MUL
    addi  x5, x0, 7
    addi  x6, x0, 6
    mul   x7, x5, x6        # 42
    sd    x7, 16(x31)

    # Test 4: DIV
    addi  x8, x0, 100
    addi  x9, x0, 7
    div   x10, x8, x9       # 14
    sd    x10, 24(x31)

    # Test 5: REM
    rem   x11, x8, x9       # 2
    sd    x11, 32(x31)

    # Test 6: AND/OR/XOR
    addi  x12, x0, 0xF0
    addi  x13, x0, 0x0F
    and   x14, x12, x13     # 0
    or    x15, x12, x13     # 0xFF
    xor   x16, x12, x13     # 0xFF
    sd    x14, 40(x31)
    sd    x15, 48(x31)
    sd    x16, 56(x31)

    # Test 7: Shifts
    addi  x17, x0, 1
    slli  x18, x17, 10      # 0x400
    sd    x18, 64(x31)

    # Test 8: SLT
    addi  x19, x0, -5
    addi  x20, x0, 5
    slt   x21, x19, x20     # 1
    sd    x21, 72(x31)

    # Fim
    addi  x22, x0, 0xAA
    sd    x22, 80(x31)

    ebreak
