---
title: Introducing Rustybot (part 1 of n)
author: drmorr
date: 2020-12-21 23:30:00-08:00
tags: [rust, robots]
---

## So you want to build a robot?

It all started when I decided I was going to build a quadcopter.  But not just any quadcopter, I was going to get all
the parts and put it together myself!  And then I was going to write the flight control system (in Rust, of course) so
that it could fly autonomously and do tasks for me, like flying over to the front door to see who just rang my doorbell.

That's doable in a weekend, right?  Right?

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/NaboQwhxK3gMU/giphy.gif"/>
    <figcaption> This is from The Walking Dead so I can only assume that this dude gets his face violently ripped off
      right after he says this.
    </figcaption>
  </figure>
</details>

So anyways, that's how I found myself building a control system in Rust for a robot that stays on the ground and is not
powered by batteries that might spontaneously combust. 

## The basics: hardware and software

I'm not super-interested in the hardware side of things and I wanted to get right to the software for the control
system, so I bought an [Arduino Uno](https://store.arduino.cc/usa/arduino-uno-smd-rev3) and a [pre-assembled
Zumo robot body](https://www.pololu.com/product/2510) that came with a bunch of features I knew I'd want to learn how to
use, including an array of IR sensors I can use for line detection and a 3-axis accelerometer for determining spatial
orientation.  I also purchased an [ultrasonic rangefinder](https://www.adafruit.com/product/172) for long-range object
detection.

The Arduino Uno uses an Atmel Atmega328p AVR microcontroller, and I really wanted to not write code in C; fortunately
for me, AVR support for Rust was merged into nightly [earlier this year](http://www.avr-rust.com)!  So I was pretty much
golden and could get right to the fun stuff.  All I had to figure out how to program the thing! 

After looking around the various embedded Rust projects, I ended up using [@Rahix's](https://github.com/Rahix)
[`avr-hal`](https://github.com/Rahix/avr-hal) crate, which is in turn based off the
[`embedded-hal`](https://github.com/rust-embedded/embedded-hal) project by the [embedded Rust
team](https://github.com/rust-embedded/wg#the-hal-team) (n.b. I briefly looked at the
[`ruduino`](https://github.com/avr-rust/ruduino) project, but I was having trouble getting it to compile and I wanted to
keep some of the abstractions less tied to the AVR processor, since I'm imagining at some point I'm going to need to
move to a Cortex ARM processor -- especially when I eventually build my quadcopter :D)

The first task was to just get the [blinky example](https://github.com/Rahix/avr-hal/blob/master/boards/arduino-uno/examples/uno-blink.rs)
to compile.  This took a bit of finagling, particularly since I'm running Windows but doing all my development on the
Windows Subsystem for Linux.  I don't remember all the different combinations I tried, but eventually settled on having
the source stored on the Windows host, but using `rustc` from Ubuntu for compilation.  I also tried to get VSCode to
work with this setup, but was never able to successfully get it to work, so gave up.  Anyways, once I got blinky
working, I started exploring some of the robot peripherals.  The Zumo libraries of course are all in C, and I wasn't
wild about trying to do some weird cross-language linking or whatever, so decided the easiest thing to do would be to
just port them to Rust.  I got the IR sensor array working and the motor drivers working, and then, like any software
engineer worth their salt, decided it was time to rewrite the entire project from scratch!  Which brings us to the meat
of this series of blog posts, embedded asynchronous robotics with Rust!

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/xT5LMCJyj3w0XFPbtS/giphy.gif"/>
    <figcaption>Why, yes they are, Bob.  Yes, they are.</figcaption>
  </figure>
</details>

## Embedded asynchronous robotics with Rust

Over the course of getting the sensors and motors to work, I made two realizations that led me down the path of
asynchronous programming: the first was that I was spending a _lot_ of time calling `arduino_uno::delay_ms`, which just
didn't seem very efficient to me.  Every component (the motors, the sensors, even the LED) requires some time to wait
for the hardware to catch up.  Two examples: I wanted to avoid putting undue strain on the motors and the chassis of the
robot by not making abrupt changes in velocity, so I implemented a system that would allow the controller to set a
target value and then it would gradually adjust the motor's actual speed to match the target.  Second, the IR sensor
array I'm using works by turning on some infrared LEDs and then measuring the time it takes for the light to bounce back
-- the longer it takes, the darker the surface, more or less.

Now, from a power-draw perspective, the motors far outweigh anything that I'm doing on the Arduino board, but it still
didn't sit well with me that I'm just busy-looping away in all these different components.  More importantly, though I
wanted to build something that was able to respond to inputs immediately, which busy-looping doesn't do.  If the sensors
detect something, but I'm in the middle of the motor-update loop, I have to wait until the motors finish their work
before handling the sensor input.  Now in "normal" computers we have threads and a CPU scheduler to handle this, but
for my purposes that's overkill.  Since I'm going to be in charge of everything running on the bot, [cooperative
multitasking](https://en.wikipedia.org/wiki/Cooperative_multitasking) is good enough, and luckily for me, Rust has just
[standardized](https://rust-lang.github.io/async-book/01_getting_started/01_chapter.html) on how to do this in the
language!

I've done a _bit_ of asynchronous work in the past, but never really understood the mechanisms under the hood; so this
project definitely threw me into the deep end!  I modelled my approach off two sources, the excellent
[blogpost](https://lights0123.com/blog/2020/07/25/async-await-for-avr-with-rust/) by Ben Schattinger, and the work by
the [async-on-embedded](https://github.com/rust-embedded-community/async-on-embedded) team.  These were great starting
points, but I still ran into a bunch of gotchas along the way.  So I'm going to try to walk through all the steps I took
and how I resolved them, and hopefully maybe help some other folks as well.

## Hold up, how does this asynchronous thing work, anyways???

I don't want to spend a _ton_ of time in the blog post going over asynchronous programming in general; there's plenty of
resources out there for that, such as the [async Rust book](https://rust-lang.github.io/async-book/).  But there's no
"official" way to do async on AVR at the time of writing, so I needed to get my hands dirty a little bit.  First, I
needed to understand the basics of how Rust does asynchronous programming.  

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/e7i6KJU8jBMvS/giphy.gif">
    <figcaption>Just so we're all clear, this is <i>not</i> my robot.</figcaption>
  </figure>
</details>

The core concept for async programming is pretty easy to understand: we've got a bunch of tasks and an executor which is
responsible for running those tasks, and when a task doesn't have any work to do it yields control back to the executor.
This is _cooperative_ multitasking because the tasks have to work together: if one task never yields, none of the other
tasks will run (in contrast to threaded multitasking, in which the executor will yank control back from tasks whenever
it feels like).  Every language implements this a little bit differently, but in Rust the core primitive is a `Future`;
a `Future` object has a pretty simple interface[^1]:

```
fn poll(
    mut self: core::pin::Pin<&mut Self>, 
    ctx: &mut core::task::Context,
) -> core::task::Poll<Self::Output>
```

Ok, hang on a sec, there's actually a lot in here that needs unpacking.  Let's start with the return value; every future
returns a `core::task::Poll<T>`, which is an enum with two possible values, `Pending` and `Ready(T)`.  The idea here is
that periodically the executor will poll each of the tasks by calling this function, and if the future has finished,
it will return `Ready(T)`, where `T` is the type of the expected output.  If the future has more work to do, it will
(optionally) advance the state of the future (i.e., do some more work), and then return `Pending`.  If the future
breaks the cooperative multitasking contract (for example, by sticking an infinite loop in `poll`), then control will
never get yielded back to the executor and none of the other tasks will execute.

The key thing to wrap your head around with async programming in Rust is that _every_ asynchronous task in Rust is a
`Future` (and thus has a `poll` method), whether it's obvious or not.  When you use the `async` and `await` keywords,
all you're doing is taking advantage of some syntactic sugar that has been built into the Rust compiler; under the hood,
Rust converts that function into a `Future` with a `poll` method.  This future object is actually a mini state machine,
where the current state represents where we last paused and what work we need to do next.  I'm not going to go into
details about how this works here, there's plenty of other excellent blogs out there on the topic (such as [this
one](https://tmandry.gitlab.io/blog/posts/optimizing-await-1/)).  Instead, what I want to focus on here is how we can
get these futures running on AVR processor.

### Pin the tail on the Selfie

So, how can we get these futures running on an AVR processor?  Let's go back to that polling function; the first
argument in there is a mutable reference to `self`, just like we expect, but it's got this funky `Pin` type -- what's
going on there?  Well, remember, under the hood, futures are mini state machines, and they need someplace to store their
state, specifically someplace that isn't the stack (you can imagine things would go horribly wrong when the stack frame
containing the future's state gets popped).  So the `Pin` type just promises the compiler that the data being pointed to
won't change memory locations.  There are a lot of subtleties here, but for our purposes, there's two types of things
that are `Pin`:

1. `static` objects
2. Dynamically-allocated objects (as long as nothing moves them around in memory)

The first is easy; my robot code has a bunch of `static mut` objects sprinkled around to keep track of the state of
various futures (e.g., the [`SENSOR_TRIGGERED`](https://github.com/drmorr0/rustybot/blob/34981a6312b836c2dc62a7a6e8db8724442ada79/src/uno/zumo_sensors.rs#L24)
bitfield keeps track of the state of the IR sensors on the robot).

"But wait!?" I hear you saying.  "`static mut` objects are `unsafe`, and also they're bad!!!!"  And yea, you're probably
right; so the pattern I've tried to adopt in my code is to only have `static mut` variables that need to be referenced
from an interrupt context.  Everything else should be dynamically allocated.

"But wait!?" I hear you saying again.  "You don't have a heap, how do you dynamically allocate anything???"  Well, the
obvious answer here is: write a heap.  In my code, you'll see that all my futures are wrapped in calls to
`Allocator::get().new(future())`; the `Allocator` is some code I stole with slight modification from the
[async-on-embedded team](https://github.com/rust-embedded-community/async-on-embedded/blob/master/async-embedded/src/alloc.rs).
This code implements a simple [bump allocator](https://os.phil-opp.com/allocator-designs/#bump-allocator), which grabs
an array of memory and provides a simple interface for storing things `static`-ally in that array.  It never
de-allocates anything and never moves anything around, so we can be sure that this satisfies `Pin`[^2].

### Context?  Context?  Is there a Context in here?

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/Xs2ry2K0ADD7G/giphy.gif"/>
  </figure>
</details>

The last thing I'm going to cover in this post is the second argument to `poll`, which caused me quite a bit of
confusion.  The [Rust docs](https://doc.rust-lang.org/core/task/struct.Context.html) simply say

> The `Context` of an asynchronous task.  Currently, Context only serves to provide access to a `&Waker` which can be
> used to wake the current task.

Ok... I guess that's helpful, but what's a `Waker`?

> A `Waker` is a handle for waking up a task by notifying its executor that it is ready to be run.  This handle
> encapsulates a `RawWaker` instance, which defines the executor-specific wakeup behavior.

Well, ok.  What's a `RawWaker`?

> A `RawWaker` allows the implementor of a task executor to create a Waker which provides customized wakeup behavior.
> It consists of a data pointer and a virtual function pointer table (vtable) that customizes the behavior of the
> `RawWaker`.

Alright, we're getting pretty darned far down this rabbit hole now, but I'll bite.  What's the vtable do?

> A virtual function pointer table (vtable) that specifies the behavior of a `RawWaker`.  The pointer passed to all
> functions inside the vtable is the data pointer from the enclosing `RawWaker` object.  The functions inside this
> struct are only intended to be called on the data pointer of a properly constructed `RawWaker` object from inside the
> `RawWaker` implementation. Calling one of the contained functions using any other data pointer will cause undefined
> behavior.

I don't know if I'm just dense, but this is all clear as mud to me.  How the heck does this `Context` get constructed?
Why are there twenty billion layers of indirection here?  What's the data pointer inside the `Waker` supposed to be?
How does that get added?  The async Rust book isn't much help here either, because it makes all these assumptions that
you'll have things like, oh, I dunno, threads and stuff.  Which we definitely don't have here.

So anyways, after many hours of spinning myself around in circles and banging my head on my keyboard, I finally got it.
Let's answer one question first: why do we have so many layers of indirection?  It has to do with that `data` pointer --
the Rust executors don't have any idea what type of tasks they're running, so everything has to be accessed via untyped
pointers, which is clearly `unsafe`.  So that's what all the `Raw*` functions do, and the un-`Raw` versions are wrappers
so that we don't have to sprinkle `unsafe` everywhere in our code.  So far pretty standard.  The only design I question
is whether the `Context` object is really necessary; I assume it's there so that we can maybe someday pass additional
metadata into the tasks, but right now it's just this extra layer that doesn't do anything.

The other thing that's a bit confusing is that we have a nesting of `Context -> Waker -> RawWaker`, but you actually
_construct_ this in reverse order.  You have to create a `RawWaker` object, and then call `Waker::from_raw` on it, and
then you call `Context::from_waker` on the `Waker`.  I guess this is fine, but after going around in so many circles it
was one more thing that I had to keep going back to.  "Wait, _how_ do I construct a context, again??"

Anyways, once I sorted out all the layers here, things got a lot easier.  We'll discuss this more next time, but for now
we can just say that for my code, every `Future` gets an attached `id` field, and the `Context` object stores a pointer
to this ID.  That way, when we need to decide what future to wake up, we can just reference the stored ID pointer and
pass that along.

## Wrapping up

Just for completeness' sake, let me diagram where we're going in the next post.  I'm going to show you how I created an
executor for AVR, which more-or-less does the following:

```
while True:
    for future in futures:
        if future.not_ready:
            continue

        context = make_context_for_future(future.id)
        future.poll(context)
    sleep
```

Each of the future objects for my robot boils down to a `Waiter` object, which just registers an "compare" value with the
AVR Timer0 object, which will trigger an interrupt when that value is hit.  When a certain number of milliseconds have
passed, the comparator interrupt looks at the future ID stored in the pending future and passes that along to the
executor so that it can wake the task up and do some more more work (spoiler warning: we have to patch `llvm` to get
this to produce correct assembly code):

```
TIMER0_COMPA():  # interrupt
    for future in waiting_futures:
        if current_time >= future.wake_time:
            future.wake()
```

From here, the executor wakes up and `poll`s all of the waiting futures, and the cycle continues.  Along the way, we'll
discover at least one more compiler bug before we get everything working!  But we will get there, I promise.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="/assets/img/posts/2020-12-21/rustybot.gif"/>
    <figcaption>Just in case you were wondering, this is where we're going.  Next stop: world domination!!!!</figcaption>
  </figure>
</details>

Thanks for reading,

~drmorr


[^1]: I'm always going to include the fully-namespaced types in these posts so it's clear what you need to `use` to
    replicate this.  Also, since I'm targeting AVR, which doesn't support `std`, I'm using the `core` library for
    everything.

[^2]: Fun fact: when you only have 2KB of RAM, maybe don't allocate half of it for your heap, or you're gonna start
    overwriting your stack eventually.  That was a fun bug to track down.
