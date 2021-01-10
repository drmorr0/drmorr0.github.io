---
title: Patching LLVM and rustc
author: drmorr
date: 2021-01-09 19:23:00-08:00
tags: [rust, llvm]
---

This post is just an aside; As I mentioned in my last post, there is a compiler bug in LLVM that is resulting in
incorrect code being generated for AVR with Rust.  I made some vague assertions in a footnote about "just follow the
directions and you'll be fine" because I couldn't remember how to do it, and then I ended up having to figure out how to
rebuild my toolchain today.  So I'm mostly posting these instructions for my own benefit, but maybe someone else will
find them useful too.

1. Download the [patch file](https://reviews.llvm.org/file/data/le54xtn3ihujx3httuqp/PHID-FILE-pbdxd3wrmhhspzqev3yc/D87631.diff)
2. If this is your first time building `rustc`, run `git clone https://github.com/rust-lang/rust`; otherwise, go into
   your checked-out version of Rust and `git pull`.
3. `git submodule update --init --recursive`
4. `cd src/llvm-project`
5. `git apply patch.diff`, where `patch.diff` is the file you downloaded in step 1.
6. `mkdir build && cd build`
7. `cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release ../llvm`
8. `cmake --build . -- -j24` (or whatever number of build processes you want to run in parallel instead of 24)
9. `cd ../../..`
10. `./x.py build --stage 2 library/core library/proc_macro`
11. `rustup toolchain link stage2 build/x86_64-unknown-linux-gnu/stage2`

And then you're done!  In your project directory, run `rustup override set stage2` to use the compiler you just built.
