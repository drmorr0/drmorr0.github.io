---
title: Introducing Rustybot (part 3 of n)
author: drmorr
date: 2021-02-26 23:31:00-08:00
tags: [rust, robots]
---

> N.B. This is the third part of a series about programming an Arduino robot using Rust's async primitives (Part
> [1](https://objectdisoriented.evokewonder.com/posts/introducing-rustybot-part-1/), 
> [2](https://objectdisoriented.evokewonder.com/posts/introducing-rustybot-part-2/), 3).  If you just want to skip to
> the source code, click [here](https://github.com/drmorr0/rustybot).

## Now we're cooking with gas

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/XEINWA0DF6KRAZ0APL/giphy.gif"/>
    <figcaption>Yep.  Definitely cooking with gas.</figcaption>
  </figure>
</details>

So I've made some significant progress since my last update.  The first thing to point out is that I got a [hardware
debugger](https://www.microchip.com/Developmenttools/ProductDetails/ATATMEL-ICE).  For reasons that will become clear
shortly, the primitive debugging techniques I outlined in my last post went from "annoying but workable" to "no longer
actually possible."  I was also pleased to see that the ATMEL-ICE debugger supports various Cortex ARM processors, which
I am anticipating migrating to at some point in the future.  And, that purchase has already paid off massively!  The
only downside is that it means my toolchain is a little less convenient, and I have to spend more time in Atmel Studio,
which I don't love, but whatever, it's fine.

That said, the purchase of the ATMEL-ICE prompted a bunch of _other_ purchases which I've been putting off for a while
and didn't _really_ want to make right now.  See, the ICSP connector (which the debugger attaches to) on the Arduino
board sticks out the top of the board, and the board gets mounted upside-down on the Zumo robot.  Which means that I
can't actually plug the debugger in while the board was attached to the robot---kinda defeating the point.  So, I
swapped the connector around so it sticks out the other side.  Yay!  But, I managed to make a total hash of the board
because my soldering iron tip was too large.  Boo.  Fortunately everything still works.  Yay!  But, well, it ain't
pretty.

So I caved and bought a set of smaller tips for my soldering iron, along with a few other components that'll come in
handy down the line.  But anyways, let's not focus on my soldering incompetence any longer, and instead focus on my
programming incompetence!

## A laundry list of stupid mistakes I've made

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/9jObH9PkVPTyM/giphy.gif"/>
    <figcaption>I'm sure this is the only time he says this, right?</figcaption>
  </figure>
</details>

Having already identified two compiler bugs with Rust's AVR support, it made every _other_ bug that I found that much
harder to troubleshoot, since I didn't trust the underlying system.  So let's play a fun game!  I'm going to write down
a list of bugs and for each one you have to guess whether it's a compiler bug or not.  Ready?  Let's go!

1. After I worked through all the various compiler bugs and finally got my async executor working with one `Future` (one
   that just blinked the LED), I tried to add a second `Future` into the mix.  Weirdly, adding a second future object
   caused everything to panic.  I spent a long time tracing through the assembly trying to understand what was
   happening, and it seemed like the creation of the second `Future` was wiping out all the data for the first one.  I
   finally tracked the problem down to the line where I called `Allocator::get().new(future2)` (`Allocator` is my custom
   bump allocator implementation, and `get()` is supposed to return a pointer to the singleton allocator
   object).  Then I realized that my implementation looked like this:
   ```rust
   impl Allocator {
       pub fn get() -> &'static mut Allocator {
           if !ALLOCATOR_INITIALIZED {
              ALLOCATOR = Allocator { ... }
           }
           &ALLOCATOR
       }
   }
   ```
   Which, if you'll observe, never sets the `ALLOCATOR_INITIALIZED` variable, so I was re-zeroing out my "fake heap"
   space every time I created a new future.  Verdict: **not** a compiler error.
1. After I solved that issue, I had a different weird issue occur with two futures.  The first future was again set to
   blink an LED, and the second was supposed to control the motor.  What actually happened was that the LED was blinking
   at weird, inconsistent frequencies.  In fact, the LED was toggling whenever the first _or_ the second future woke up!
   This one stumped me for quite a while, and then I realized that the problem was in this block of code:
   ```rust
   for i in 0..self.work_queue_len {
       let id = self.work_queue[i];
       unsafe {
           let waker = Waker::from_raw(RawWaker::new(&id as *const _ as *const _, &VTABLE));
           let mut ctx = Context::from_waker(&waker);
           Pin::new_unchecked(self.drivers[id].assume_init_mut()).poll(&mut ctx);
       }
   }
   ```
   The issue here is that `&id` pointer.  Whatever it's pointing to is obviously going to get overwritten when the
   for-loop goes out of scope, and actually as I'm writing this, I'm having a bit of trouble reconstructing how
   this code resulted in the exact failure mode I observed, but the short version is that every future ended up holding
   a pointer to the same address location, which was the id for the LED's future.  Hence, the LED blinked a bunch.
   Verdict: **not** a compiler bug.
1. I don't totally remember at what point I discovered this bug, but at one point I was allocating 1KB of my internal
   RAM for my "fake heap", which was causing me to overflow my stack semi-regularly.  The Arduino only _has_ 2KB of RAM,
   and I certainly didn't need that much for my futures, but it took me a while to realize what was going on.  Verdict:
   **not** a compiler bug.
1. This is actually related to the previous bug, but I'd been observing weird issues regularly with `ufmt`.  It appeared
   to just randomly panic whenever I tried to write out data to the serial port.  There was also all this weird
   gibberish that was getting dumped into SRAM and taking up a ton of space (like, all the characters of the alphabet,
   plus lots of random other characters).  It took me a _very long time_ to connect the dots here---if you have a
   formatting library, it has to have all the characters it needs to format things loaded into memory somewhere, and
   there are a lot of characters.  I also suspect (but haven't verified) that `ufmt` has to make a lot of nested
   function calls to actually succeed at formatting things correctly, which would cause it to overflow the stack and
   panic.  I didn't actually think this was a compiler bug, but I _did_ think that `ufmt` was a buggy library for quite
   a while; I'm a bit embarrased at how long it took me to figure out the actual problem.  I ended up just deleting that
   dependency, because I'm not gonna have my robot hooked up to a USB cable while it's driving around anyways.  Verdict:
   **not** a compiler (or a library) bug.

## Motors and IR sensors and magnetometers, oh my!

For the rest of this post, I'm going to talk briefly about each of the various components that I have working on the
robot, and mention any pitfalls or gotchas that came up along the way.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/N8wR1WZobKXaE/giphy.gif"/>
    <figcaption>DARPA TV?  More like <i>DERP</i>A TV, amirite?</figcaption>
  </figure>
</details>

### The motor controllers

The motors were the first non-LED component that I got working with my async code, and it took me a little while to
figure out the right way to structure the code for these more complex futures.  For a long while, I had a
`MotorController` struct that had almost no data or methods, and then a function that would take a pointer to a
`MotorController` as its first argument and then return the future.  The motor future itself was a closure with a bunch
of state that was "local" to the function that defined it:

```rust
pub struct MotorController {
    pub left_target: f32,
    pub right_target: f32,
}

pub fn get_motor_driver(
    controller_ref: &'static RefCell<MotorController>,
    mut left_direction_pin: PB0<Output>,
    mut left_throttle_pin: PB2<Pwm<pwm::Timer1Pwm>>,
    mut right_direction_pin: PD7<Output>,
    mut right_throttle_pin: PB1<Pwm<pwm::Timer1Pwm>>,
) -> &'static mut dyn Future<Output = !> {
    let mut current_left_value: f32 = 0.0;
    let mut current_right_value: f32 = 0.0;
    let future = async move || {
        loop {
            if let Ok(controller) = controller_ref.try_borrow() {
                // Move the current value closer to the target value in here
            }
            Waiter::new(UPDATE_DELAY_MS).await;
        }
    };
    Allocator::get().new(future())
}
```

Eventually I decided that this was a less-than-ideal way to structure things, so I moved the `current_left/right_value`
fields into the `MotorController` object.  Unfortunately, this prevented the motors from ever turning on, because of
that pesky `RefCell` -- essentially, both the controller and the state machine were trying to write to the `RefCell` at
the same time, which is forbidden.  So then I finally figured out how to restructure things so that I didn't have to use
the `RefCell`, and then I could make the `get_motor_driver` function an actual method on the `MotorController` object,
which takes a `static` pointer to `self`.  The big breakthrough here was that the `MotorController` needed _separate_
`RefCell`s which behave like a poor-man's version of "channels" in Golang:

```rust
pub struct MotorController {
    left: RefCell<SingleMotorController<LeftDirectionPin, LeftThrottlePin>>,
    left_target: RefCell<f32>,
    right: RefCell<SingleMotorController<RightDirectionPin, RightThrottlePin>>,
    right_target: RefCell<f32>,
}
```

The target values are only ever _written to_ by my state machine "brain", and only ever _read_ by the `MotorController`.
The actual motor values themselves are only read and written to by the `MotorController`, so I can ensure that they
aren't being borrowed mutably twice.

### The IR sensors

My initial pass at getting the IR sensors to work was just a straight port of the [code provided for the
Zumo](https://github.com/pololu/zumo-shield-arduino-library/blob/master/QTRSensors.cpp).  When I then went to convert it
to an async version, I ran into problems because the sensor read time happens on the order of microseconds, but my async
executor's minimum resolution was in milliseconds.  I _could_ block the executor for a millisecond or two while I read
the IR sensors, but that kinda went against the entire spirit of this project; and plus, I wasn't too sure how that
would mess with the timings (which are clearly not too important for this robot, but will be important for my
quadcopter).

The first thing I tried here was changing the resolution of the async executor to be microseconds instead of
milliseconds, but this failed horribly.  Timings were completely off, cycles were getting dropped, it was just all over
the place.  My suspicion is that microsecond resolution is just too fine for this processor.  Conceivably maybe we could
get away with something like 100-μs resolution, but that was starting to get too complicated and it still didn't solve
my problem with the IR sensor array.

After some conversation with a friend, and a re-reading of the AVR spec, I finally figured out how to do this.
It turns out that you can enable per-pin interrupts when the value on the pin changes.  So to read the IR sensors, I do
the following:

1. Drive the IR sensors high
1. Record the "start time" for reading the sensors
1. Enable the per-pin interrupts; when these ISRs fire, they record the number of microseconds since we started
   (which directly correlates with the brightness of the surface the sensors are over).
1. Wait (asynchronously) a couple milliseconds
1. Read the final values out from the sensor array

Et voilà!  We can keep our millisecond-resolution executor and record microsecond-resolution values from our sensors!

### The IMU

If you recall, the Zumo has an inertial measurement unit (IMU), which consists of a 3-axis magnetometer along with an
accelerometer.  Getting this working was another pretty straight translation from the [provided C
code](https://github.com/pololu/zumo-shield-arduino-library/blob/master/ZumoIMU.cpp); I guess to be clear, I haven't
gotten the accelerometer working yet because I haven't needed it thus far.

The most challenging bit here was learning how the TWI (two-wire interface, pronounced "TWEEEEEEE", obviously) works on
the Arduino.  It also took me a bit of time to understand how the [Rust interface with the
TWI](https://rahix.github.io/avr-hal/arduino_uno/type.I2cMaster.html) works in `avr-hal`.  It was at this point that I
realized I needed to update the version of `avr-hal` I was using, which changed some dependencies, which required me to
rebuild my `rustc` toolchain, which resulted in my [last post](https://objectdisoriented.evokewonder.com/posts/patching-llvm/).
For the want of a nail, and all that jazz.

### EEPROM

In actuality, the EEPROM was the earliest thing I got working with my Arduino board, well before I started doing any
robotics; until now I hadn't figured out a good use for it, but both the IR sensors and the IMU need some calibration
data to work effectively, so I dug up my old code and dropped it in so that I can store my calibration data in the
EEPROM and not have to re-calibrate every time I turn the robot on.  The only thing I dislike about this bit is that my
EEPROM address map is just a long list of constant values; it seems like there ought to be a better way to encode this,
but I haven't figured it out yet.

So that's it!  Everything I've gotten working on the robot so far!  In my next post, I will talk about the state machine
"brain" of the robot, along with some concerns I have for using a lot of async code in an embedded project.

<details>
  <summary>click to expand</summary>
  <figure>
    <img src="https://media.giphy.com/media/3oriff8rzy11Laah2g/giphy.gif"/>
    <figcaption>I can neither confirm nor deny whether my robot is using the brain of Homer Simpson.</figcaption>
  </figure>
</details>

Thanks for reading,

~drmorr
