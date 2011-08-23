.so book.mac
.chapter CH:TRAP "System calls, exceptions, and interrupts"
.ig
	in progress
..
.PP 
An operating system must handle system calls, exceptions, and
interrupts.  With a system call a user program can ask for an
operating system service, as we saw at the end of the last chapter.  
.italic Exceptions 
are illegal program
actions that generate an interrupt.  Examples of illegal programs actions
include divide by zero, attempt to access memory outside segment
bounds, and so on. 
.italic Interrupts 
are generated by hardware devices that
need attention of the operating system.  For example, a clock chip may
generate an interrupt every 100 msec to allow the kernel to implement
time sharing.  As another example, when the disk has read a block from
disk, it generates an interrupt to alert the operating system that the
block is ready to be retrieved.
.PP
The kernel handles all interrupts, rather than processes
handling them, because in most cases only the kernel has the
required privilege and state. For example, in order to time-slice
among processes in response the clock interrupts, the kernel
must be involved, if only to force uncooperative processes to
yield the processor.
.PP
In all three cases, the operating system design must arrange for the
following to happen.  The system must save the processor's registers for future
transparent resume.  The system must be set up for execution
in the kernel.  The system must chose a place for the kernel to start
executing. The kernel must be able to retrieve information about the
event, e.g., system call arguments.  It must all be done securely; the system
must maintain isolation of user processes and the kernel.
.PP
To achieve this goal the operating system must be aware of the details
of how the hardware handles system calls, exceptions, and interrupts.
In most processors these three events are handled by a single hardware
mechanism.  For example, on the x86, a program invokes a system call
by generating an
interrupt using the 
.code int
instruction.   Similarly, exceptions generate an interrupt too.  Thus, if
the operating system has a plan for interrupt handling, then the
operating system can handle system calls and exceptions too.
.PP
The basic plan is as follows.  An interrupts stops the normal
processor loop—read an instruction, advance the program counter,
execute the instruction, repeat—and starts executing a new sequence
called an interrupt handler.  Before starting the interrupt handler,
the processor saves its registers, so that the operating system
can restore them when it returns from the interrupt.
A challenge in the transition to and from the interrupt handler is
that the processor should switch from user mode to kernel mode, and
back.
.PP
A word on terminology: Although the official x86 term is interrupt,
x86 refers to all of these as traps, largely because it was the term
used by the PDP11/40 and therefore is the conventional Unix term.
This chapter uses the terms trap and interrupt interchangeably, but it
is important to remember that traps are caused by the current process
running on a processor (e.g., the process makes a system call and as a
result generates a trap), and interrupts are caused by devices and may
not be related to the currently running process.
For example, a disk may generate an interrupt when
it is done retrieving a block for one process, but
at the time of the interrupt some other process may be running.
This
property of interrupts makes thinking about interrupts more difficult
than thinking about traps, because interrupts happen
concurrently with other activities, and requires the designer to think
about parallelism and concurrency.  A topic that we will address in
Chapter \*[CH:LOCK].
.PP
This chapter examines the xv6 trap handlers,
covering hardware interrupts, software exceptions,
and system calls.
.\"
.section "X86 protection"
.\"
.PP
The x86 has 4 protection levels, numbered 0 (most privilege) to 3
(least privilege).  In practice, most operating systems use only 2
levels: 0 and 3, which are then called "kernel" and "user" mode,
respectively.  The current privilege level with which the x86 executes
instructions is stored in
.code %cs
register,
in the field CPL.
.PP
On the x86, interrupt handlers are defined in the interrupt descriptor
table (IDT). The IDT has 256 entries, each giving the
.code %cs
and
.code %eip
to be used when handling the corresponding interrupt.
.ig
pointer to the IDT table.
..
.PP
To make a system call on the x86, a program invokes the 
.code int
.italic n
instruction, where 
.italic n 
specifies the index into the IDT. The
.code int
instruction performs the following steps:
.IP \[bu] 
Fetch the 
.italic n 'th
descriptor from the IDT,
where 
.italic n
is the argument of
.code int .
.IP \[bu] 
Check that CPL in 
.code %cs
is <= DPL,
where DPL is the privilege level in the descriptor.
.IP \[bu] 
Save
.code %esp
and
.code %ss
in a CPU-internal registers, but only if the target segment
selector's PL < CPL.
.IP \[bu] 
Load
.code %ss
and
.code %esp
from a task segment descriptor.
.IP \[bu] 
Push
.code %ss .
.IP \[bu] 
Push
.code %esp .
.IP \[bu] 
Push
.code %eflags .
.IP \[bu] 
Push
.code %cs .
.IP \[bu] 
Push
.code %eip .
.IP \[bu] 
Clear some bits of
.code %eflags .
.IP \[bu] 
Set 
.code %cs
and
.code %eip
to the values in the descriptor.
.PP
The
.code int
instruction is a complex instruction, and one might wonder whether all
these actions are necessary.  The check CPL <= DPL allows the kernel to
forbid systems for some privilege levels.  For example, for a user
program to execute 
.code int 
instruction succesfully, the DPL must be 3.
If the user program doesn't have the appropriate privilege, then 
.code int
instruction will result in
.code int 
13, which is a general protection fault.
As another example, the
.code int
instruction cannot use the user stack to save values, because the user
might not have set up an appropriate stack so that hardware uses the
stack specified in the task segments, which is setup in kernel mode.
.PP
When an 
.code int
instruction completes and there was a privilege-level change (the privilege
level in the descriptor is lower than CPL), the following values are
on the stack specified in the task segment:
.P1
        ss
        esp
        eflags
        cs
        eip
esp ->  error code
.P2
If the 
.code int
instruction didn't require a privilege-level change, the following
values are on the original stack:
.P1
         eflags
         cs
         eip
esp ->   error code
.P2
After both cases, 
.code %eip
is pointing to the address specified in the descriptor table, and the
instruction at that address is the next instruction to be executed and
the first instruction of the handler for
.code int
.italic n .
It is job of the operating system to implement these handlers, and
below we will see what xv6 does.
.PP
An operating system can use the
.code iret
instruction to return from an
.code int
instruction. It pops the saved values during the 
.code int
instruction from the stack, and resumes execution at the saved 
.code %eip .
.\"
.section "Code: The first system call"
.\"
.PP
The last chapter ended with 
.code initcode.S
invoking a system call.
Let's look at that again
.line initcode.S:/'T_SYSCALL'/ .
The process pushed the arguments
for an 
.code exec
call on the process's stack, and put the
system call number in
.code %eax .
The system call numbers match the entries in the syscalls array,
a table of function pointers
.line syscall.c:/'syscalls'/ .
We need to arrange that the 
.code int
instruction switches the processor from user space to kernel space,
that the kernel invokes the right kernel function (i.e.,
.code sys_exec ),
and that the kernel can retrieve the arguments for
.code sys_exec .
The next few subsections describes how xv6 arranges this for system
calls, and then we will discover that we can reuse the same code for
interrupts and exceptions.
.\"
.section "Code: Assembly trap handlers"
.\"
.PP
Xv6 must set up the x86 hardware to do something sensible
on encountering an
.code int
instruction, which causes the processor to generate a trap.
The x86 allows for 256 different interrupts.
Interrupts 0-31 are defined for software
exceptions, like divide errors or attempts to access invalid memory addresses.
Xv6 maps the 32 hardware interrupts to the range 32-63
and uses interrupt 64 as the system call interrupt.
.ig
pointer to the x86 exception table with vector numbers (DE, DB, ...)
..
.PP
.code Tvinit
.line trap.c:/^tvinit/ ,
called from
.code main ,
sets up the 256 entries in the table
.code idt .
Interrupt
.code i
is handled by the
code at the address in
.code vectors[i] .
Each entry point is different, because the x86 provides
does not provide the trap number to the interrupt handler.
Using 256 different handlers is the only way to distinguish
the 256 cases.
.PP
.code Tvinit
handles
.code T_SYSCALL ,
the user system call trap,
specially: it specifies that the gate is of type "trap" by passing a value of
.code 1
as second argument.
Trap gates don't clear the 
.code IF_FL
flag, allowing other interrupts during the system call handler.
.PP
The kernel also sets the system call gate privilege to
.code DPL_USER ,
which allows a user program to generate
the trap with an explicit
.code int
instruction.
xv6 doesn't allow processes to raise other interrupts (e.g., device
interrupts) with
.code int ;
if they try, they will encounter
a general protection exception, which
goes to vector 13. 
.PP
When changing protection levels from user to kernel mode, the kernel
shouldn't use the stack of the user process, because it may not be valid.
The user process may be malicious or
contain an error that causes the user
.code esp 
to contain an address that is not part of the process's user memory.
Xv6 programs the x86 hardware to perform a stack switch on a trap by
setting up a task segment descriptor through which the hardware loads a stack
segment selector and a new value for
.code %esp .
The function
.code switchuvm
.line vm.c:/^switchuvm/ 
stores the address of the top of the kernel stack of the user
process into the task segment descriptor.
.ig
TODO: Replace SETGATE with real code.
..
.PP
When a trap occurs, the processor hardware does the following.
If the processor was executing in user mode,
it loads
.code %esp
and
.code %ss
from the task segment descriptor,
pushes the old user
.code %ss
and
.code %esp
onto the new stack.
If the processor was executing in kernel mode,
none of the above happens.
The processor then pushes the
.code eflags ,
.code %cs ,
and
.code %eip
registers.
For some traps, the processor also pushes an error word.
The processor then loads
.code %eip
and
.code %cs
from the relevant IDT entry.
.PP
xv6 uses a Perl script
.line vectors.pl:1
to generate the entry points that the IDT entries point to.
Each entry pushes an error code
if the processor didn't, pushes the interrupt number, and then
jumps to
.code alltraps .
.PP
.code Alltraps
.line trapasm.S:/^alltraps/
continues to save processor registers: it pushes
.code %ds ,
.code %es ,
.code %fs ,
.code %gs ,
and the general-purpose registers
.lines trapasm.S:/Build.trap.frame/,/pushal/ .
The result of this effort is that the kernel stack now contains a
.code struct
.code trapframe 
.line x86.h:/trapframe/
containing the processor registers at the time of the trap.
.ig
XXX picture.
..
The processor pushes
.code ss ,
.code esp ,
.code eflags ,
.code cs , 
and
.code eip .
The processor or the trap vector pushes an error number,
and 
.code alltraps 
pushes the rest.
The trap frame contains all the information necessary
to restore the user mode processor registers
when the kernel returns to the current process,
so that the processor can continue exactly as it was when
the trap started.
.PP
In the case of the first system call, the saved 
.code eip
is the address of the instruction right after the 
.code int
instruction.
.code cs 
is the user code segment selector.
.code eflags
is the content of the eflags register at the point of executing the 
.code int
instruction.
As part of saving the general-purpose registers,
.code alltraps
also saves 
.code %eax ,
which contains the system call number for the kernel
to inspect later.
.PP
Now that the user mode processor registers are saved,
.code alltraps
can finishing setting up the processor to run kernel C code.
The processor set the selectors
.code %cs
and
.code %ss
before entering the handler;
.code alltraps
sets
.code %ds
and
.code %es
.lines "'trapasm.S:/movw.*SEG_KDATA/,/%es/'" .
It sets 
.code %fs
and
.code %gs
to point at the 
.code SEG_KCPU
per-CPU data segment
.lines "'trapasm.S:/movw.*SEG_KCPU/,/%gs/'" .
.PP
Once the segments are set properly,
.code alltraps
can call the C trap handler
.code trap .
It pushes
.code %esp,
which points at the trap frame it just constructed,
onto the stack as an argument to
.code trap
.line "'trapasm.S:/pushl.%esp/'" .
Then it calls
.code trap
.line trapasm.S:/call.trap/ .
After
.code trap 
returns,
.code alltraps
pops the argument off the stack by
adding to the stack pointer
.line trapasm.S:/addl/
and then starts executing the code at
label
.code trapret .
We traced through this code in Chapter \*[CH:MEM]
when the first user process ran it to exit to user space.
The same sequence happens here: popping through
the trap frame restores the user mode registers and then
.code iret
jumps back into user space.
.PP
The discussion so far has talked about traps occurring in user mode,
but traps can also happen while the kernel is executing.
In that case the hardware does not switch stacks or save
the stack pointer or stack segment selector;
otherwise the same steps occur as in traps from user mode,
and the same xv6 trap handling code executes.
When 
.code iret
later restores a kernel mode 
.code %cs ,
the processor continues executing in kernel mode.
.\"
.section "Code: C trap handler"
.\"
.PP
We saw in the last section that each handler sets
up a trap frame and then calls the C function
.code trap .
.code Trap
.line 'trap.c:/^trap!(/'
looks at the hardware trap number
.code tf->trapno
to decide why it has been called and what needs to be done.
If the trap is
.code T_SYSCALL ,
.code trap
calls the system call handler
.code syscall .
We'll revisit the two
.code cp->killed
checks in Chapter \*[CH:SCHED].  \" XXX really?
.PP
After checking for a system call, trap looks for hardware interrupts
(which we discuss below). In addition to the expected hardware
devices, a trap can be caused by a spurious interrupt, an unwanted
hardware interrupt.
.ig
give a concrete example.
..
.PP
If the trap is not a system call and not a hardware device looking for
attention,
.code trap
assumes it was caused by incorrect behavior (e.g.,
divide by zero) as part of the code that was executing before the
trap.  
If the code that caused the trap was a user program, xv6 prints
details and then sets
.code cp->killed
to remember to clean up the user process.
We will look at how xv6 does this cleanup in Chapter \*[CH:SCHED].
.PP
If it was the kernel running, there must be a kernel bug:
.code trap
prints details about the surprise and then calls
.code panic .
.PP
[[Sidebar about panic:
panic is the kernel's last resort: the impossible has happened and the
kernel does not know how to proceed.  In xv6, panic does ...]]
.PP
.\"
.section "Code: System calls"
.\"
.PP
For system calls,
.code
trap
invokes
.code syscall
.line syscall.c:/'^syscall'/ .
.code Syscall 
loads the system call number from the trap frame, which
contains the saved
.code %eax ,
and indexes into the system call tables.
For the first system call, 
.code %eax
contains the value 9,
and
.code syscall
will invoke the 9th entry of the system call table, which corresponds
to invoking
.code sys_exec .
.PP
.code Syscall
records the return value of the system call function in
.code %eax .
When the trap returns to user space, it will load the values
from
.code cp->tf
into the machine registers.
Thus, when 
.code exec
returns, it will return the value
that the system call handler returned
.line "'syscall.c:/eax = syscalls/'" .
System calls conventionally return negative numbers to indicate
errors, positive numbers for success.
If the system call number is invalid,
.code syscall
prints an error and returns \-1.
.PP
Later chapters will examine the implementation of
particular system calls.
This chapter is concerned with the mechanisms for system calls.
There is one bit of mechanism left: finding the system call arguments.
The helper functions argint and argptr, argstr retrieve the 
.italic n 'th 
system call
argument, as either an integer, pointer, or a string.
.code argint 
uses the user-space 
.code esp 
register to locate the 
.italic n'th 
argument:
.code esp 
points at the return address for the system call stub.
The arguments are right above it, at 
.code esp+4.
Then the nth argument is at 
.code esp+4+4*n .  
.PP
.code argint 
calls 
.code fetchint
to read the value at that address from user memory and write it to
.code *ip .  
.code fetchint 
can simply cast the address to a pointer, because the user and the
kernel share the same page table, but the kernel must verify that the
pointer by the user is indeed a pointer in the user part of the address
space.
The kernel has set up the page-table hardware to make sure
that the process cannot access memory outside its local private memory:
if a user program tries to read or write memory at an address of
.code p->sz 
or above, the processor will cause a segmentation trap, and trap will
kill the process, as we saw above.
Now though, the kernel is running and it can derefence any address that the user might have passed, so it must check explicitly that the address is below
.code p->sz 
.PP
.code argptr
is similar in purpose to 
.code argint : 
it interprets the 
.italic n th 
system call argument.
.code argptr 
calls 
.code argint 
to fetch the argument as an integer and then checks
if the integer as a user pointer is indeed in the user part of
the address space.
Note that two checks occur during a call to 
code argptr .
First, the user stack pointer is checked during the fetching
of the argument.
Then the argument, itself a user pointer, is checked.
.PP
.code argstr 
is the final member of the system call argument trio.
It interprets the
.italic n th 
argument as a pointer.  It ensures that the pointer points at a
NUL-terminated string and that the complete string is located below
the end of the user part of the address space.
.PP
The system call implementations (for example, sysproc.c and sysfile.c)
are typically wrappers: they decode the arguments using 
.code argint ,
.code argptr , 
and 
.code argstr
and then call the real implementations.
.PP
In chapter \*[CH:MEM],
.code sys_exec
uses these functions to get at its arguments.
.\"
.section "Code: Interrupts"
.\"
.PP
Devices on the motherboard can generate interrupts, and xv6 must setup
the hardware to handle these interrupts.  Without device support xv6
wouldn't be usable; a user couldn't type on the keyboard, a file
system couldn't store data on disk, etc. Fortunately, adding
interrupts and support for simple devices doesn't require much
additional complexity.  As we will see, interrupts can use the same
code as for systems calls and exceptions.
.PP
Interrupts are similar to system calls, except devices generate them
at any time.  There is hardware on the motherboard to signal the CPU
when a device needs attention (e.g., the user has typed a character on
the keyboard). We must program the device to generate an interrupt, and
arrange that a CPU receives the interrupt. 
.PP
Let's look at the timer device and timer interrupts.  We would like
the timer hardware to generate an interrupt, say, 100 times per
second so that the kernel can track the passage of time and so the
kernel can time-slice among multiple running processes.  The choice of
100 times per second allows for decent interactive performance while
not swamping the processor with handling interrupts.  
.PP
Like the x86 processor itself, PC motherboards have evolved, and the
way interrupts are provided has evolved too.  The early boards had a
simple programmable interrupt controler (called the PIC), and you can
find the code to manage it in
.code picirq.c .
.ig
picture?
..
.PP
With the advent of multiprocessor PC boards, a new way of handling
interrupts was needed, because each CPU needs an interrupt controller
to handle interrupts send to it, and there must be a method for
routing interrupts to processors.  This way consists of two parts: a
part that is in the I/O system (the IO APIC,
.code ioapic.c), 
and a part that is attached to each processor (the
local APIC, 
.code lapic.c).
Xv6 is designed for a
board with multiple processors, and each processor must be programmed
to receive interrupts.
.ig
picture?
..
.PP
To also work correctly on uniprocessors, Xv6 programs the programmable
interrupt controler (PIC)
.line picirq.c:/^picinit/ .  
Each PIC can handle a maximum of 8 interrupts (i.e., devices) and
multiplex them on the interrupt pin of the processor.  To allow for
more than 8 devices, PICs can be cascaded and typically boards have at
least two.  Using
.code inb
and 
.code outb
instructions Xv6 programs the master to
generate IRQ 0 through 7 and the slave to generate IRQ 8 through 16.
Initially xv6 programs the PIC to mask all interrupts.
The code in
.code timer.c
sets timer 1 and enables the timer interrupt
on the PIC
.line timer.c:/^timerinit/ .
This description omits some of the details of programming the PIC.
These details of the PIC (and the IOAPIC and LAPIC) are not important
to this text but the interested reader can consult the manuals for
each device, which are referenced in the source files.
.PP
On multiprocessors, xv6 must program the IOAPIC, and the LAPIC on
each processor.
The IO APIC has a table and the processor can program entries in the
table through memory-mapped I/O, instead of using 
.code inb
and 
.code outb
instructions.
During initialization, xv6 programs to map interrupt 0 to IRQ 0, and
so on, but disables them all.  Specific devices enable particular
interrupts and say to which processor the interrupt should be routed.
For example, xv6 routes keyboard interrupts to processor 0
.line console.c:/^consoleinit/ .
Xv6 routes disk interrupts to the highest numbered processor on the
system
.line ide.c:/^ideinit/ .
.PP
The timer chip is inside the LAPIC, so that each processor can receive
timer interrupts independently. Xv6 sets it up in
.code lapicinit
.line lapic.c:/^lapicinit/ .
The key line is the one that programs the timer
.line lapic.c:/lapicw.TIMER/ .
This line tells the LAPIC to periodically generate an interrupt at
.code IRQ_TIMER,
which is IRQ 0.
Line
.line lapic.c:/lapicw.TPR/
enables interrupts on a CPU's LAPIC, which will cause it to deliver
interrupts to the local processor.
.PP
A processor can control if it wants to receive interrupts through the
.code IF
flags in the eflags register.
The instruction
.code cli
disables interrupts on the processor by clearing 
.code IF , 
and
.code sti
enables interrupts on a processor.  Xv6 disables interrupts during
booting of the main cpu
.line bootasm.S:/cli/
and the other processors
.line entryother.S:/cli/ .
The scheduler on each processor enables interrupts
.line proc.c:/sti/ .
To control that certain code fragments are not interrupted, xv6
disables interrupts during these code fragments (e.g., see
.code switchuvm
.line vm.c:/^switchuvm/ ).
.PP
The timer interrupts through vector 32 (which xv6 chose to handle IRQ
0), which xv6 setup in
.code idtinit 
.line main.c:/idtinit/ .
The only difference between vector 32 and vector 64 (the one for
system calls) is that vector 32 is an interrupt gate instead of a trap
gate.  Interrupt gates clears
.code IF ,
so that the interrupted processor doesn't receive interrupts while it
is handling the current interrupt.  From here on until
.code trap , 
interrupts follow
the same code path as system calls and exceptions, building up a trap frame.
.PP
.code Trap
when it's called for a time interrupt, does just two things:
increment the ticks variable 
.line trap.c:/ticks++/ , 
and call
.code wakeup . 
The latter, as we will see in Chapter \*[CH:SCHED], may cause the
interrupt to return in a different process.
.ig
Turns out our kernel had a subtle security bug in the way it handled traps... vb 0x1b:0x11, run movdsgs, step over breakpoints that aren't mov ax, ds, dump_cpu and single-step. dump_cpu after mov gs, then vb 0x1b:0x21 to break after sbrk returns, dump_cpu again.
..
.ig
point out that we are trying to be manly with interrupts, by turning them on often in the kernel.  probably would be just fine to turn them on only when the kernel is idle.
..
.\"
.section "Real world"
.\"
polling

memory-mapped I/O versus I/O instructions

interrupt handler (trap) table driven.

Interrupt masks.
Interrupt routing.
On multiprocessor, different hardware but same effect.

interrupts can move.

more complicated routing.

more system calls.

have to copy system call strings.

even harder if memory space can be adjusted.

Supporting all the devices on a PC motherboard in its full glory is
much work, because the drivers to manage the devices can get complex.
