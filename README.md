__Cryoz__ implements fast, zero-copy deserialization of Zig types. Specifically, it serializes types such that they can be trivially re-interpreted as the original type (ish) without any in-memory copies or transformations.

Currently _alpha_ quality, not recommended for production use.

In cryoz, the deserialization function is simple one-liner:

```zig
// The lifetime of the returned pointer is tied to the lifetime of the passed data slice.
pub fn deserialize(comptime T: type, data: []const u8) !*const Serialized(T) {
    return @ptrCast(@alignCast(data.ptr));
}
```

This library heavily exploits compile-time metaprogramming in Zig. It was heavily inspired by [rkyv](https://rkyv.org/), which implements zero-copy deserialization in Rust. When [turbopuffer](https://turbopuffer.com) switched from bincode to rkyv, we saw a [65% reduction in CPU consumption from queries and a noticable latency improvement](https://x.com/pushrax/status/1799156380059967856).