 
.text
.globl main
main:
    li a0, 256
    .loop:
        addi a0, a0, -1
        bnez a0, .loop
        
        
    ebreak
