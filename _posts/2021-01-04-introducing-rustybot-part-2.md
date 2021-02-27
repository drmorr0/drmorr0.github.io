---
title: Introducing Rustybot (part 2 of n)
author: drmorr
date: 2021-01-04 23:00:00-08:00
tags: [rust, robots]
---

> N.B. This is the second part of a series about programming an arduino robot using Rust's async primitives (Part
> [1](https://objectdisoriented.evokewonder.com/posts/introducing-rustybot-part-1/), 2,
> [3](https://objectdisoriented.evokewonder.com/posts/introducing-rustybot-part-3/)).  If you just want to skip to
> the source code, click [here](https://github.com/drmorr0/rustybot).

## PSA: click on all the things

Ok, one bit of housekeeping first: a few people complained that the animated GIFs from the last post were distracting
and made it hard to read, which, as much as I hate to admit it, is actually a fair complaint.  Instead of getting rid of
them entirely, I've started sticking them in collapsible elements so that you don't get completely overwhelmed by my wit
and brilliance.  Like this:

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/kFgzrTt798d2w/giphy.gif"/>
    <figcaption>C'mon, you didn't seriously expect anything other than this, did you?</figcaption>
  </figure>
</details>

I guess you _could_ also just skip over those elements entirely since there'll never be anything important in there, but
really---where's the fun in that???

Alrighty then, with that out of the way, let's jump back in where we left off.  Which was, uhh... hmmm...

## What were we doing, again?

In the last post, we discussed the setup for this project, some of the basics of asynchronous programming with Rust, and
how to get that all working on an Arduino.  We ended the post talking about `Future` objects, which if you recall, have
a single function that they _promise_ (see what I did there?  eh?  eh??) to implement:

```rust
fn poll(
    mut self: core::pin::Pin<&mut Self>, 
    ctx: &mut core::task::Context,
) -> core::task::Poll<Self::Output>
```

As a reminder, _every_ asynchronous operation in Rust boils down to a `Future`; when you use the `async`/`await`
keywords, these are just some syntactic sugar that instruct the compiler on how to build an internal state-machine
representation of your future.  We also talked about the two arguments to this function and implications they had for
writing asynchronous code on AVR, but there's still one piece left that we need to discuss: the return value.

Futures can obviously return all kinds of different values, depending on the application, so each `Future` needs to
specify what the type is for the value it will eventually return.  For my purposes, I'm not expecting my futures to
_ever_ return -- each one is just a control loop for a different component in the robot.  So each of my futures has a
fully-qualified type of `core::future::Future<Output = !>`, which (at time of writing) uses an unstable Rust feature, so
I have to stick 

```rust
#![feature(never_type)]
```

at the top of my `main.rs` file.  But what the heck, this entire robot is built using nightly/unstable features, what's
one more to throw into the mix?

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/3o6Zt6eQnQ8UUPhV60/giphy.gif"/>
    <figcaption>This guy has a very smart-looking goatee, he seems quite trustworthy</figcaption>
  </figure>
</details>

Now, the actual return type of the future is a `core::task::Poll` enum, which has two possible variants: `Pending`, and
`Ready(T)`, where `T` is just the type of `Self::Output`.  The idea is this: the executor can use literally whatever
method it wants to poll the futures (including just a dumb busy-loop), and if the future is still waiting or has more
work to do, the executor will get back `Pending`, but if the future has completed, then it will get back a `Ready` value
that encapsulates the actual value returned by the function.  But in this case, we don't actually care about the `Ready`
value, because we "know" that the futures will never return; so my executor just throws away the return value from
`poll`:

```rust
let _ = future.poll(&mut ctx);
```

To summarize, each of my robot components is controlled by a `Future` with the following form:

```rust
let future = async move || {
    loop {
        // do stuff
    }
};
```

But what is actually going on inside that cryptically-labelled `do stuff` block???

## Time for a compiler bug!

To answer that question, let's take a look at the `Future` object that underlies all of my control loops.  It's called a
`Waiter`, and its job (as you might expect) is to wait until a certain amount of time has passed.  It's pretty simple,
so I'm just going to paste the whole code here:

```rust
pub struct Waiter {
    trigger_time_ms: u32,
    interrupt_set: bool,
}

impl Future for Waiter {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, ctx: &mut Context) -> Poll<Self::Output> {
        if millis() >= self.trigger_time_ms {
            self.interrupt_set = false;
            return Poll::Ready(());
        } else if !self.interrupt_set {
            register_timed_waker(self.trigger_time_ms, ctx.waker().clone());
            self.interrupt_set = true;
        }
        Poll::Pending
    }
}
```

The first thing to notice is that `Waiter` actually _does_ return, once the elapsed time has passed, so it has a return
type of `()` instead of `!`.  The way that it works is pretty simple; when you instantiate a new `Waiter`, you provide a
time in milliseconds[^1] when you want it to expire.  The first time you call `poll` (as long as the expiration time
hasn't already passed), we simply call `register_timed_waker`, which sets up an interrupt to fire when the trigger time
has passed.  Every subsequent time you call `poll`, it returns `Pending`, unless we've passed the trigger time, and then
we return `Ready`.  Pretty straightforward, right?

Of course not.  Nothing about this is straightforward.  Why would you think otherwise?

I'm going to skip over the details of `register_timed_waker` and the interrupt routine for now (though I may come back
to this in a later post), because there's a fundamental bug in the Rust compiler that prevents this whole thing from
working.  I first read about this on [Ben Schattinger's blog](https://lights0123.com/blog/2020/07/25/async-await-for-avr-with-rust/#to-do),
so I at least knew about it ahead of time, but decided to go ahead and try it out for myself anyways.  Maybe it would
magically work for me (spoiler warning: it did not).

The gist of the bug is that (if you recall from my first post), at the bottom of this `Context/Waker/RawWaker` stack is
a virtual function pointer table that we have to use in order to tell the executor what tasks need to be woken up.
These function pointers get translated into an `icall` (indirect call) assembly instruction, which takes as its only
argument a memory location containing the address of the function that should be called.  And (as it stands right at the
time of writing) LLVM generates this function address incorrectly, meaning that instead of jumping to the start of the
function, the program counter jumps to somewhere the middle of the function.  As you might imagine, this completely
corrupts your program state and causes everything to panic.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/An4MkAbxeiyqY/giphy.gif"/>
    <figcaption>Don't panic!</figcaption>
  </figure>
</details>

This might have sunk the entire project right here, except that the fix is fairly straightforward and there is a
[patch](https://reviews.llvm.org/D87631) already in existence.  Reading through the review comments there, most of the
issues are with the tests and not the code itself; after [chatting with the developers](https://gitter.im/avr-rust/Lobby?at=5f8693701cbba72b63dc44d5)
I decided the easiest course of action would be to just apply the patch to a custom Rust toolchain.  I mean honestly,
how hard could that be?

Actually not that hard!  The only real gotcha was that Rust bundles its own copy of LLVM which includes a few
language-specific optimizations, instead of relying on the upstream version of LLVM.  So I first cloned LLVM and the
patch didn't apply cleanly, and then I did some more reading, and then cloned the [Rust version of
LLVM](https://github.com/rust-lang/llvm-project/tree/8d78ad13896b955f630714f386a95ed91b237e3d), to which the patch
applied cleanly, I built it, and I was off and running![^2]

## Time for another compiler bug!

So---what have we accomplished so far?  We've made some `Future`s, we've set them up to trigger when a timer expires,
we've patched LLVM so that the function pointers work correctly; now, we just need to tell our executor to wake up the
tasks.  Seems like it shouldn't be too hard, right[^3]?  No, but there are lots of little gotchas along the way.  Let's
look at the function that gets called when we want to wake a future up:

```rust
unsafe fn wake(data: *const ()) {
    let e = Executor::get();
    let val = *(data as *const usize);
    e.add_work(val);
}
```

Remember that `wake` is being called from an interrupt context.  The idea here is that the interrupt gets a pointer to
the (singleton) `Executor` object, and then tells the executor that the future needs to wake up.  If you recall from
part one of this series, the `data` argument is just the value that's been encased in 4 layers of indirection inside the
`Context` object---in this case, the `id` of the future.  The `add_work` function is simply telling the executor that
the future with that ID needs to wake up and do something.

Now, some details about the executor: the futures are all stored in an array, and the futures' IDs are just an index
into that array.  So when the executor's run-loop spins back around, it'll see that ID present in some kind of data
structure and then use it to `poll` the corresponding entry in the futures array.  So far so good; but, there's actually
a few different implementation choices we need to make here that potentially could make things complicated.
Specifically, how should we represent the "list of futures that need to be polled"? The naïve solution is to stick the
IDs in a `Vec` and call it a day---the executor could just pop everything off the vector in every iteration.

So I tried doing that here, using the [`heapless`](https://docs.rs/heapless/0.5.6/heapless/) implementation of `Vec`;
essentially, the API is the same as what's in `std`, except that you have to declare at compile time what the maximum
size of your vector is, and you're not ever allowed to grow beyond that size.  So I wired everything up, turned it on,
and... immediately got a panic.  It took a bit of digging to discover why, but I _believe_ it's another [compiler/code
generation bug](https://github.com/rust-lang/rust/issues/78260).  You can go read the bug report for the details, but
the short version is as follows:

Whenever a `call` or `icall` instruction is encountered, the processor is entering a new function context, and all
the CPU registers and other state needs to be saved onto the stack so that when the function call returns it can pick up
where it left off.  This is done with a sequence of `push` instructions at the start of every subroutine, and a sequence
of `pop` instructions at the end.  The naïve way to do this is to just `push` _every_ register, but this is a waste of
time and stack space, since many subroutines won't use every CPU register.  So to optimize, the compiler needs to figure
out which registers are being used, and only save those ones.  In this particular bug, it appears that the compiler is
doing this computation incorrectly: some registers are used by a subroutine but are not `push`ed first, leading to a
corruption of the program state, which eventually results in a panic.

I actually have no idea what is causing this.  I'm only able to reproduce it when I'm using the `heapless` library from
inside an interrupt context, and when the subroutine I'm calling isn't `inline`.  I'm _pretty sure_ this isn't a bug
with my code, but whether it's a bug with `heapless`, `rustc`, or LLVM, I really have no idea.  So I filed a bug report
and decided to move on.  I was initially able to work around this by manually `push`-ing the problem registers at the
start of `add_work`, and `pop`-ing them at the end, but in the end I stopped using `heapless` entirely and the problem
went away.  Unfortunately, since I know there's a problem but I don't know what causes it, now every time something
panics I waste a bunch of time checking to see if the register state is getting corrupted, which inevitably, it is not.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/jA4T01RxBv77W/giphy.gif">
    <figcaption>Author's depiction of the rust AVR compiler corrupting my program state</figcaption>
  </figure>
</details>

That's a nice segue into the last thing I want to talk about in this post, but I will just briefly mention that I ended
up using a bitvector to track which tasks needed awakening.  I haven't done rigorous timing estimations but I believe
this is a much more efficient way to store this data, and it makes some of the code easier as well.  But more about that
some other time.  The last thing I'm going to discuss in this post is...

## How the %&(# am I supposed to debug anything???

I wanted to ~~complain~~ talk a bit about the tools that I'm using, because they all suck.  Mostly this is due to
problems of my own making, but it's made finding any bugs (of which I've had many) much harder than it needs to be.  So
to remind you: I'm writing code in Rust, using the Windows Subsystem for Linux 2[^4].  I'm using `avr-gcc` (the WSL
Ubuntu version) to compile my code, because the Windows version didn't work.  I'm using `avrdude` (the Windows version)
to flash my Arduino, because a) WSL2 doesn't have access to the USB ports, and b) when I tried using WSL1--which does
have USB port access--the Linux version of `avrdude` didn't work.  I don't actually remember why these various things
did or did not work, so it's possible that I was doing something wrong or the situation has improved somewhat.  But
needless to say, the situation is... non-ideal.

So anyways, my debugging process, given this setup is as follows:

1. Flash my code and see what happens.  I've configured my panic handler to rapidly blink the LED on the Arduino
   whenever the code panics, so as long as something breaks after the LED pin is enabled, I can easily tell if
   something's wrong (of course, this doesn't always happen).
2. If something's broken and I suspect it's in a spot where I have easy access to the `Usart` register, I use the
   [`ufmt`](https://docs.rs/ufmt/0.1.0/ufmt/) crate to write debug information out on the USB port.  This is annoying
   for two reasons: 1) WSL2 doesn't have access to the USB ports on my computer, so I have to read the data from
   PowerShell, and 2) for reasons I have not identified, `ufmt` sometimes causes things to panic on its own, for
   different reasons than whatever I'm trying to debug.  The first issue is extra annoying because I haven't figured out
   how to make PowerShell cleanly _close_ the USB port when I'm done listening, which means I have to physically
   disconnect and reconnect the Arduino before I can flash any code changes.  The second issue I _suspect_ is due to a
   stack overflow, but I've never been able to actually isolate the problem.
3. If the caveman's version of "print debugging" described in step 2 doesn't work, I load my binary into a simulator.  I
   have two different simulators at my disposal, Atmel Studio (running in Windows), and [`simavr`](https://github.com/buserror/simavr) 
   (running in WSL Ubuntu, and connected up to `avr-gdb`).  Both of these debuggers have good and bad things about them,
   which means I'm very often switching back and forth between them to try to identify issues.

   First, let's talk about Atmel Studio; you _can_, in fact, give it an ELF binary that you've compiled somewhere else
   and feed it through Atmel's simulator, and it will even include some source code hints in its disassembler output.
   Moreover, you can easily see the state of the entire CPU _and_ all of the external RAM at once, which makes it 
   _much_ easier to identify bugs.  Unfortunately, due to (I think) some sort of WSL->Windows weirdness, it's not able
   to _find_ all the source files, so it's often lacking information about where I actually _am_ in the code.  I also
   can't set a breakpoint in the source code, I have to set breakpoints in the assembly.  Couple this with the fact that
   it has a slightly wonky user interface, and it means the debugging experience leaves some things to be desired.

   On the other hand, `simavr` plus `avr-gdb` gives a much nicer experience in some ways, since it actually knows where
   my source files are, and I can see the source and the assembly side-by-side, and set breakpoints in either.  `simavr`
   also understands and can read a simulated serial port, which means the debugging information from step 2 will appear
   in the simulator as well (if Atmel Studio can do this, I haven't figured out how).  The downsides here are that it's
   much harder to see the CPU state (I have to explicitly print it every time, instead of just having it open in a
   separate window), and it's nearly _impossible_ to see the values in RAM.  One particularly nice feature of Atmel
   Studio is that it will highlight changes in memory and in the CPU state since the last breakpoint, and I have no idea
   how to do that in gdb, despite the fact that I think it's a superiour debugger in almost every other way.

I _think_ there are probably solutions out there somewhere for most of the toolchain issues that I've encountered, but
after a moderate amount of Googling I haven't been able to resolve them.  I'm either using the wrong search terms, or
I'm an idiot, or possibly both.  I would definitely love to hear about any improvements I could make in my setup going
forward, though I'm hopeful that as I start moving into some higher-level logic, instead of the nitty-gritty of getting
an async executor working, that debugging will get a bit easier.

In the next post in this series, I'll air my laundry list of "random other bugs I encountered along the way", and also
talk about how I got the IR sensors on the robot working.  But that's all I've got for now.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/2KAGlmkPywhZS/giphy.gif"/>
    <figcaption>A laundry list of bugs</figcaption>
  </figure>
</details>

Thanks for reading,

~drmorr

[^1]: I briefly experimented with allowing you to set timers to expire in microseconds, but this didn't end up working
    very well.  There were still many other bugs in the platform when I tried this, so whether it didn't work because of
    other bugs or because that's just too fine of a resolution for the Arduino to handle in a reasonable fashion I'm not
    quite sure.  I _suspect_ that the Arduino just struggles to keep up with things at that level of resolution, though.

    I might come back to this in the future, but once I got everything working properly I did some really rudimentary
    timing analysis on my interrupts; if there are no `Future`s that need to be woken up, the ISR takes 4-5μs to
    complete, and if there _is_ a `Future` that needs awakening, it takes more like 10-20μs, if I recall correctly.
    Thus it seems pretty reasonable to me that we could get stuck in an ISR when the next interrupt needs to fire,
    especially if we're trying to wake something up every 30-50μs.  And anyways, this was fairly consistent with the
    behaviour I was seeing, which was _extremely_ inconsistent waking behaviour and very noticeable timing delays.

    This will all become relevant when I get to talking about the infrared sensor array, which needs to delay on the
    order of tens of microseconds before reading.  I eventually figured out a better solution for this, and decided that
    I didn't want to hassle with trying to make a system work at that level of timing precision for this particular
    project, though I may need to for my quadcopter.

    I'm also very interested in doing some profiling to see if I can optimize my ISRs any further than they already are,
    or maybe they're not even worth optimizing at this point; but I think having a standard set of tools to allow me to
    do this kind of analysis will be useful in the future, regardless.

[^2]: Building the toolchain isn't _too_ difficult, but it takes a little bit of time to get correct.  I more-or-less
    just followed the instructions on [How to Build and Run the Compiler](https://rustc-dev-guide.rust-lang.org/building/how-to-build-and-run.html).
    Since I wanted an actual "production" compiler, I built everything three times to get a "stage 2" compiler, and then
    also compiled the `core` library for use with my code.  From there I created a custom toolchain, and then set up my
    environment to use my custom toolchain for Rustybot.  I sadly didn't document the entire list of steps to get this
    working, and it required a little bit of fiddling, but only a little bit.  The only thing I still haven't figured
    out is some of the "extra" tools like `rustfmt`, but I have hacked around this for now by just hardcoding a path to
    a different version of `rustfmt` in my config files.

[^3]: Are you sensing a pattern here?

[^4]: The `2` will become important momentarily.
