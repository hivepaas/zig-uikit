# Shaders

Two shaders, and they are the only ones the toolkit has: a vertex shader that
expands a unit square into one instanced quad, and a fragment shader that
evaluates the quad's signed distance field.

```sh
glslang -V quad.vert -o quad.vert.spv
glslang -V quad.frag -o quad.frag.spv
```

The compiled `.spv` files are **committed**, so building the toolkit does not
need a shader compiler. Only changing a shader does.

## Why these are GLSL and not Zig

Writing the shaders in Zig would have been better than writing them in GLSL,
and not for taste: `src/raster.zig` already contains the same distance field as
a Zig function, so the shader and the software reference rasteriser could have
been *the same source* rather than two transcriptions that can drift. Zig has a
SPIR-V backend, so this looked possible.

It is not, in Zig 0.17, and the reason is specific. Compiling

```zig
extern var out_uv: @Vector(2, f32) addrspace(.output);

export fn vertMain() callconv(.spirv_vertex) void { ... }
```

with `-target spirv64-vulkan` produces a valid SPIR-V module in which the
builtins are decorated correctly — `OpDecorate %vertex_index BuiltIn 42`,
`OpDecorate %position BuiltIn 0` — and `out_uv` has **no `Location`
decoration at all**. Vulkan requires one on every non-builtin interface
variable, so the module cannot be used in a graphics pipeline. There is no way
to supply the decoration: `std.spirv` exposes builtins and inline `OpControlBarrier`-style
assembly, but decorations are module-level instructions and are not reachable
from a function body.

Two further obstacles sit behind that one. The backend emits `Capability Int64`
and `Capability PhysicalStorageBufferAddresses` with the
`SPV_KHR_physical_storage_buffer` extension for even a trivial shader, which is
a heavy requirement for a UI toolkit's fragment shader; and it emits
`PushConstant` variables of its own whose layout the program does not control,
so push constants and descriptor bindings are not expressible either.

Working around the missing `Location` by avoiding varyings entirely does not
help. A fragment shader could in principle recover its instance from
`gl_PrimitiveID`, but it would then have to read the quad from a storage
buffer, and that needs `Binding` and `DescriptorSet` decorations — the same
problem.

So: GLSL, compiled ahead of time, with `tools/gpu_demo.zig` comparing the
result against `src/raster.zig` pixel by pixel because the duplication is real
and has to be watched. This is worth revisiting when Zig's SPIR-V backend
supports explicit decorations.
