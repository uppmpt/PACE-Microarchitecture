.section .text
.globl _start

_start:
    # ALU immediate
    addi  x1, x0, 100
    slti  x2, x1, 200
    sltiu x3, x1, 200
    xori  x4, x1, 0xFF
    ori   x5, x1, 0x0F
    andi  x6, x1, 0x7F
    slli  x7, x1, 4
    srli  x8, x1, 2

    addi  x9, x0, -100
    srai  x10, x9, 2
    srli  x11, x9, 2

    # ALU register
    addi  x12, x0, 5
    add   x13, x1, x12
    sub   x14, x1, x12
    sll   x15, x1, x12
    slt   x16, x1, x12
    sltu  x17, x1, x12
    xor   x18, x1, x12
    srl   x19, x1, x12
    sra   x20, x9, x12
    or    x21, x1, x12
    and   x22, x1, x12

    # U-type
    lui   x23, 0x12345
    auipc x24, 0

    ebreak
