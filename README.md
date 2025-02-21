# Fork

Note that upstream hasn't been updated in a while and the build system/language has changed quite a bit since then.
This repo updates it (badly) to work with Zig 0.13 but I have very little interest in properly supporting it beyond what I use.

# Original
zamqp is a Zig wrapper around [rabbitmq-c](https://github.com/alanxz/rabbitmq-c).

## Setup
1. Install `librabbitmq`.
2. Add the following to your `build.zig` (you may need to adjust the path):
    ```zig
    step.linkLibC();
    step.linkSystemLibrary("rabbitmq");
    step.addPackagePath("zamqp", "../zamqp/src/zamqp.zig");
    ```
3. Import with `@import("zamqp")`.
