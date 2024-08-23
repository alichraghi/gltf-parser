const std = @import("std");
const builtin = @import("builtin");
const stbi = @import("stb_image");
const tracy = @import("tracy.zig");
const assert = std.debug.assert;
const bytesAsSlice = std.mem.bytesAsSlice;

const GLTF = @This();

fba_buf: []u8,
scene_name: []const u8,
scene_nodes: []const u16,
nodes: []const Node,
meshes: []const Mesh,
materials: []const Material,

pub const Node = struct {
    mesh: ?u16,
    children: []const u16,
    scale: [3]f32,
    rotation: [3]f32,
    translation: [3]f32,
};

pub const Mesh = struct {
    primitives: []Primitive,
};

pub const Material = struct {
    albedo: Texture,
};

pub const Texture = struct {
    width: u32,
    height: u32,
    data: [:0]u8,
};

pub const Primitive = struct {
    indices: ?[]u32,
    material: ?u16,
    position: ?[]@Vector(3, f32),
    normal: ?[]@Vector(3, f32),
    tangent: ?[]@Vector(4, f32),
    texcoord_0: ?[]@Vector(2, f32),
    texcoord_1: ?[]@Vector(2, f32),
    color_0: ?[]@Vector(4, f32),
    joints_0: ?[]@Vector(4, u16),
    weights_0: ?[]@Vector(4, f32),
};

const JsonChunk = struct {
    asset: struct {
        generator: ?[]const u8 = null,
        version: []const u8,
    },
    scene: u16,
    scenes: []struct {
        name: []const u8 = "Main Scene",
        nodes: []u16,
    },
    nodes: []struct {
        mesh: ?u16 = null,
        children: []u16 = &.{},
        scale: @Vector(3, f32) = .{ 1, 1, 1 },
        rotation: @Vector(3, f32) = .{ 0, 0, 0 },
        translation: @Vector(3, f32) = .{ 0, 0, 0 },
    },
    meshes: []struct {
        primitives: []struct {
            attributes: struct {
                POSITION: ?u16 = null,
                NORMAL: ?u16 = null,
                TANGENT: ?u16 = null,
                TEXCOORD_0: ?u16 = null,
                TEXCOORD_1: ?u16 = null,
                COLOR_0: ?u16 = null,
            },
            indices: ?u16 = null,
            material: ?u16 = null,
        },
    },
    materials: []struct {
        name: ?[]const u8 = null,
        pbrMetallicRoughness: struct {
            baseColorTexture: struct {
                index: u16,
            },
        },
    } = &.{},
    textures: []struct {
        sampler: u16,
        source: u16,
    } = &.{},
    images: []struct {
        name: ?[]const u8 = null,
        mimeType: []const u8,
        bufferView: u16,
    } = &.{},
    accessors: []Accessor,
    bufferViews: []BufferView,
    buffers: []struct {
        byteLength: usize,
    },

    const Accessor = struct {
        bufferView: u16,
        type: Type,
        componentType: ComponentType,
        count: usize,
        byteOffset: usize = 0,
        sparse: ?struct {} = null,
        // NOTE: min/max is required for POSITION attribute
        min: ?[]f32 = null,
        max: ?[]f32 = null,
    };

    const BufferView = struct {
        buffer: u16,
        byteLength: usize,
        byteOffset: usize = 0,
        byteStride: ?usize = null,
        target: ?Target = null,
    };
};

const Type = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT3,
    MAT4,

    fn len(ty: Type) u8 {
        return switch (ty) {
            .SCALAR => 1,
            .VEC2 => 2,
            .VEC3 => 3,
            .VEC4 => 4,
            .MAT3 => 9,
            .MAT4 => 16,
        };
    }

    fn size(ty: Type, component_type: ComponentType) u8 {
        return ty.len() * component_type.size();
    }
};

const ComponentType = enum(u16) {
    i8 = 5120,
    u8 = 5121,
    i16 = 5122,
    u16 = 5123,
    u32 = 5125,
    f32 = 5126,

    fn size(component_type: ComponentType) u8 {
        return switch (component_type) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .u32, .f32 => 4,
        };
    }

    fn max(component_type: ComponentType) u32 {
        return switch (component_type) {
            .i8 => std.math.maxInt(i8),
            .u8 => std.math.maxInt(u8),
            .i16 => std.math.maxInt(i16),
            .u16 => std.math.maxInt(u16),
            .u32 => std.math.maxInt(u32),
            .f32 => unreachable,
        };
    }
};

const Target = enum(u16) {
    ARRAY_BUFFER = 34962,
    ELEMENT_ARRAY_BUFFER = 34963,
};

pub fn parseGLB(allocator: std.mem.Allocator, data: []const u8) !GLTF {
    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    // Header
    const magic = try reader.readInt(u32, .little);
    if (magic != 0x46546C67) return error.CorruptFile;

    const version = try reader.readInt(u32, .little);
    if (version != 2) return error.OldGLTF;

    const length = try reader.readInt(u32, .little);
    assert(length > 12);

    // JSON Chunk
    var chunk_len = reader.readInt(u32, .little) catch |err| switch (err) {
        error.EndOfStream => return error.CorruptFile,
    };
    if (chunk_len % 4 != 0) return error.CorruptFile;

    const json_zone = tracy.trace(@src());
    json_zone.setName("JSON");
    json_zone.setColor(0xFFFF00);

    var chunk_type = try reader.readInt(u32, .little);
    if (chunk_type != 0x4E4F534A) return error.CorruptFile;

    const json_bytes = try allocator.alloc(u8, chunk_len);
    defer allocator.free(json_bytes);

    const read_len = try reader.read(json_bytes);
    assert(read_len == chunk_len);

    const json_res = try std.json.parseFromSlice(
        JsonChunk,
        allocator,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer json_res.deinit();

    const metadata = json_res.value;

    json_zone.end();

    // Binary Chunk
    chunk_len = reader.readInt(u32, .little) catch |err| switch (err) {
        error.EndOfStream => return error.CorruptFile,
    };
    if (chunk_len % 4 != 0) return error.CorruptFile;

    chunk_type = try reader.readInt(u32, .little);
    if (chunk_type != 0x004E4942) return error.CorruptFile;

    const buffer = data[fbs.pos..metadata.buffers[0].byteLength];

    // Parse accessors/images/etc
    const alloc_zone = tracy.trace(@src());
    alloc_zone.setName("Allocate");
    alloc_zone.setColor(0x00FF00);

    // TODO: Precisely measure needed size
    const fba_buf = try allocator.alloc(u8, buffer.len);
    var fba_instance = std.heap.FixedBufferAllocator.init(fba_buf);
    const fba = fba_instance.allocator();

    const scene = metadata.scenes[metadata.scene];

    const out_nodes = try fba.alloc(Node, metadata.nodes.len);
    const out_meshes = try fba.alloc(Mesh, metadata.meshes.len);
    const out_materials = try fba.alloc(Material, metadata.materials.len);

    alloc_zone.end();

    for (metadata.nodes, out_nodes) |node, *out_node| {
        out_node.* = .{
            // According to tracy, even calls to alloc/dupe/free with 0 size has significant time costs
            .children = if (node.children.len > 0) try fba.dupe(u16, node.children) else &.{},
            .mesh = node.mesh,
            .scale = node.scale,
            .rotation = node.rotation,
            .translation = node.translation,
        };
    }

    for (metadata.materials, out_materials) |material, *out_material| {
        const tex = metadata.textures[material.pbrMetallicRoughness.baseColorTexture.index];
        const img = metadata.images[tex.source];
        const buffer_view = metadata.bufferViews[img.bufferView];
        assert(buffer_view.byteStride == null);

        const ptr = buffer[buffer_view.byteOffset..][0..buffer_view.byteLength];

        var width: c_int = 0;
        var height: c_int = 0;
        var channels_in_file: c_int = 0;
        var image: [:0]u8 = undefined;

        if (!@hasDecl(@import("root"), "BENCHMARK_GLTF")) {
            const image_c = stbi.stbi_load_from_memory(
                ptr.ptr,
                @intCast(ptr.len),
                &width,
                &height,
                &channels_in_file,
                4,
            );
            image = @ptrCast(image_c[0..@intCast(width * height * 4 + 1)]);
        }

        out_material.* = .{
            .albedo = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .data = image,
            },
        };
    }

    for (metadata.meshes, out_meshes) |mesh, *out_mesh| {
        assert(mesh.primitives.len > 0);
        const out_primitives = try fba.alloc(Primitive, mesh.primitives.len);

        for (mesh.primitives, out_primitives) |prim, *out_prim| {
            var indices: ?[]u32 = null;
            var position: ?[]@Vector(3, f32) = null;
            var normal: ?[]@Vector(3, f32) = null;
            var tangent: ?[]@Vector(4, f32) = null;
            var texcoord_0: ?[]@Vector(2, f32) = null;
            var texcoord_1: ?[]@Vector(2, f32) = null;
            var color_0: ?[]@Vector(4, f32) = null;
            var joints_0: ?[]@Vector(4, u16) = null;
            var weights_0: ?[]@Vector(4, f32) = null;

            _ = &joints_0;
            _ = &weights_0;

            inline for (&.{
                .{ prim.indices, .index },
                .{ prim.attributes.POSITION, .position },
                .{ prim.attributes.NORMAL, .normal },
                .{ prim.attributes.TANGENT, .tangent },
                .{ prim.attributes.TEXCOORD_0, .texcoord_0 },
                .{ prim.attributes.TEXCOORD_1, .texcoord_1 },
            }) |entry| if (entry.@"0") |attr| {
                const attr_name = @tagName(entry.@"1");
                const trace = tracy.trace(@src());
                defer trace.end();
                trace.setName(attr_name);
                trace.setColor(@bitCast([_]u8{ attr_name[0], attr_name[1], attr_name[2], attr_name[attr_name.len - 1] }));

                const accessor = metadata.accessors[attr];
                const item_size = accessor.type.size(accessor.componentType);
                const buffer_view = metadata.bufferViews[accessor.bufferView];
                const stride = buffer_view.byteStride orelse item_size;
                const ptr = buffer[accessor.byteOffset + buffer_view.byteOffset ..][0..buffer_view.byteLength];
                assert(buffer_view.byteLength == accessor.count * stride);
                assert(accessor.count > 0);

                var iter = std.mem.window(u8, ptr, item_size, stride);
                var i: usize = 0;

                switch (entry.@"1") {
                    .index => {
                        assert(accessor.type == .SCALAR);
                        indices = try fba.alloc(u32, accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            indices.?[i] = switch (accessor.componentType) {
                                .u8 => @as(u8, @bitCast(slice[0..@sizeOf(u8)].*)),
                                .u16 => @as(u16, @bitCast(slice[0..@sizeOf(u16)].*)),
                                .u32 => @as(u32, @bitCast(slice[0..@sizeOf(u32)].*)),
                                else => unreachable,
                            };
                            assert(indices.?[i] != accessor.componentType.max());
                        }
                    },
                    .position => {
                        assert(accessor.type == .VEC3);
                        assert(accessor.componentType == .f32);
                        assert(accessor.min != null);
                        assert(accessor.max != null);
                        position = try fba.alloc(@Vector(3, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            position.?[i] = @bitCast(slice[0..@sizeOf([3]f32)].*);
                        }
                    },
                    .normal => {
                        assert(accessor.type == .VEC3);
                        assert(accessor.componentType == .f32);
                        normal = try fba.alloc(@Vector(3, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            normal.?[i] = @bitCast(slice[0..@sizeOf([3]f32)].*);
                        }
                    },
                    .tangent => {
                        assert(accessor.type == .VEC4);
                        assert(accessor.componentType == .f32);
                        tangent = try fba.alloc(@Vector(4, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            tangent.?[i] = @bitCast(slice[0..@sizeOf([4]f32)].*);
                            assert(tangent.?[i][3] >= -1 and tangent.?[i][3] <= 1);
                        }
                    },
                    .texcoord_0 => {
                        assert(accessor.type == .VEC2);
                        texcoord_0 = try fba.alloc(@Vector(2, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            texcoord_0.?[i] = switch (accessor.componentType) {
                                .u8 => @floatFromInt(@as(@Vector(2, u8), @bitCast(slice[0..@sizeOf([2]u8)].*))),
                                .u16 => @floatFromInt(@as(@Vector(2, u16), @bitCast(slice[0..@sizeOf([2]u16)].*))),
                                .f32 => @bitCast(slice[0..@sizeOf([2]f32)].*),
                                else => unreachable,
                            };
                        }
                    },
                    .texcoord_1 => {
                        assert(accessor.type == .VEC2);
                        texcoord_1 = try fba.alloc(@Vector(2, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            texcoord_1.?[i] = switch (accessor.componentType) {
                                .u8 => @floatFromInt(@as(@Vector(2, u8), @bitCast(slice[0..@sizeOf([2]u8)].*))),
                                .u16 => @floatFromInt(@as(@Vector(2, u16), @bitCast(slice[0..@sizeOf([2]u16)].*))),
                                .f32 => @bitCast(slice[0..@sizeOf([2]f32)].*),
                                else => unreachable,
                            };
                        }
                    },
                    .color_0 => {
                        color_0 = try fba.alloc(@Vector(4, f32), accessor.count);
                        if (accessor.type == .VEC4) {
                            while (iter.next()) |slice| : (i += 1) {
                                color_0.?[i] = switch (accessor.componentType) {
                                    .u8 => @floatFromInt(@as(@Vector(4, u8), @bitCast(slice[0..@sizeOf([4]u8)].*))),
                                    .u16 => @floatFromInt(@as(@Vector(4, u16), @bitCast(slice[0..@sizeOf([4]u16)].*))),
                                    .f32 => @bitCast(slice[0..@sizeOf([4]f32)].*),
                                    else => unreachable,
                                };
                                assert(color_0 >= .{ 0, 0, 0, 0 });
                            }
                        } else if (accessor.type == .VEC3) {
                            while (iter.next()) |slice| : (i += 1) {
                                const color_rgb: @Vector(3, f32) = switch (accessor.componentType) {
                                    .u8 => @floatFromInt(@as(@Vector(3, u8), @bitCast(slice[0..@sizeOf([3]u8)].*))),
                                    .u16 => @floatFromInt(@as(@Vector(3, u16), @bitCast(slice[0..@sizeOf([3]u16)].*))),
                                    .f32 => @bitCast(slice[0..@sizeOf([3]f32)].*),
                                    else => unreachable,
                                };
                                color_0.?[i] = .{ color_rgb[0], color_rgb[1], color_rgb[2], 1 };
                                assert(color_0 <= .{ 1, 1, 1, 1 });
                            }
                        } else unreachable;
                    },
                    .joints_0 => {
                        assert(accessor.type == .VEC4);
                        joints_0 = try fba.alloc(@Vector(4, u16), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            joints_0.?[i] = switch (accessor.componentType) {
                                .u8 => @as(@Vector(4, u8), @bitCast(slice[0..@sizeOf([4]u8)].*)),
                                .u16 => @as(@Vector(4, u16), @bitCast(slice[0..@sizeOf([4]u16)].*)),
                                else => unreachable,
                            };
                        }
                    },
                    .weights_0 => {
                        assert(accessor.type == .VEC4);
                        weights_0 = try fba.alloc(@Vector(4, f32), accessor.count);
                        while (iter.next()) |slice| : (i += 1) {
                            weights_0.?[i] = switch (accessor.componentType) {
                                .u8 => @floatFromInt(@as(@Vector(4, u8), @bitCast(slice[0..@sizeOf([4]u8)].*))),
                                .u16 => @floatFromInt(@as(@Vector(4, u16), @bitCast(slice[0..@sizeOf([4]u16)].*))),
                                .f32 => @bitCast(slice[0..@sizeOf([4]f32)].*),
                                else => unreachable,
                            };
                        }
                    },
                    else => unreachable,
                }
            };

            // TODO: joints_0
            // TODO: weights_0

            out_prim.* = .{
                .material = prim.material,
                .indices = indices,
                .position = position,
                .normal = normal,
                .tangent = tangent,
                .texcoord_0 = texcoord_0,
                .texcoord_1 = texcoord_1,
                .color_0 = color_0,
                .joints_0 = joints_0,
                .weights_0 = weights_0,
            };
        }

        out_mesh.* = .{ .primitives = out_primitives };
    }

    return .{
        .fba_buf = fba_buf,
        .scene_name = scene.name,
        .scene_nodes = try fba.dupe(u16, scene.nodes),
        .nodes = out_nodes,
        .meshes = out_meshes,
        .materials = out_materials,
    };
}

pub fn deinit(gltf: GLTF, allocator: std.mem.Allocator) void {
    if (!@hasDecl(@import("root"), "BENCHMARK_GLTF")) {
        for (gltf.materials) |material| {
            stbi.stbi_image_free(material.albedo.data.ptr);
        }
    }
    allocator.free(gltf.fba_buf);
}
