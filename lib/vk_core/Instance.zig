//! Vulkan 1.4 instance and physical-device discovery.
const Instance = @This();

const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.vk);

gpa: Allocator,
vkb: vk.BaseWrapper,
vki: vk.InstanceWrapper,
proxy: vk.InstanceProxy,

pub const api_version = vk.API_VERSION_1_4;
const validation_layer = "VK_LAYER_KHRONOS_validation";

extern fn vkGetInstanceProcAddr(instance: ?vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

pub const Options = struct {
    app_name: [*:0]const u8,
    /// Enable VK_LAYER_KHRONOS_validation if installed.
    validation: bool = false,
    extensions: []const [*:0]const u8 = &.{},
};

pub const Candidate = struct {
    pdev: vk.PhysicalDevice,
    queue_family: u32,
    props: vk.PhysicalDeviceProperties,
};

pub fn create(gpa: Allocator, opts: Options) !*Instance {
    const self = try gpa.create(Instance);
    errdefer gpa.destroy(self);
    self.gpa = gpa;
    self.vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);

    const layers = [_][*:0]const u8{validation_layer};
    const use_validation = opts.validation and try self.hasLayer(validation_layer);
    if (opts.validation and !use_validation) log.warn("{s} not available", .{validation_layer});

    const handle = try self.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = opts.app_name,
            .application_version = 0,
            .engine_version = 0,
            .api_version = api_version.toU32(),
        },
        .enabled_layer_count = if (use_validation) layers.len else 0,
        .pp_enabled_layer_names = &layers,
        .enabled_extension_count = @intCast(opts.extensions.len),
        .pp_enabled_extension_names = opts.extensions.ptr,
    }, null);
    self.vki = vk.InstanceWrapper.load(handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    self.proxy = vk.InstanceProxy.init(handle, &self.vki);
    return self;
}

pub fn destroy(self: *Instance) void {
    self.proxy.destroyInstance(null);
    self.gpa.destroy(self);
}

fn hasLayer(self: *Instance, name: []const u8) !bool {
    const props = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.gpa);
    defer self.gpa.free(props);
    for (props) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.layer_name, 0), name)) return true;
    }
    return false;
}

pub fn hasDeviceExtensions(self: *Instance, gpa: Allocator, pd: vk.PhysicalDevice, wanted: []const [*:0]const u8) !bool {
    const available = try self.proxy.enumerateDeviceExtensionPropertiesAlloc(pd, null, gpa);
    defer gpa.free(available);
    for (wanted) |want| {
        for (available) |a| {
            if (std.mem.eql(u8, std.mem.span(want), std.mem.sliceTo(&a.extension_name, 0))) break;
        } else return false;
    }
    return true;
}

/// Every Vulkan 1.4 GPU with a graphics queue, all `extensions`, and accepted by `accept`.
/// Discrete GPUs first. Caller owns the slice.
pub fn findCandidates(
    self: *Instance,
    gpa: Allocator,
    extensions: []const [*:0]const u8,
    ctx: anytype,
    comptime accept: fn (@TypeOf(ctx), *Instance, vk.PhysicalDevice) bool,
) ![]Candidate {
    const pdevs = try self.proxy.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);

    var list: std.ArrayList(Candidate) = .empty;
    errdefer list.deinit(gpa);

    for (pdevs) |pd| {
        const props = self.proxy.getPhysicalDeviceProperties(pd);
        const name = std.mem.sliceTo(&props.device_name, 0);
        if (props.api_version < api_version.toU32()) {
            log.info("skipping {s}: Vulkan < 1.4", .{name});
            continue;
        }
        if (!try self.hasDeviceExtensions(gpa, pd, extensions)) {
            log.info("skipping {s}: missing required extensions", .{name});
            continue;
        }
        if (!accept(ctx, self, pd)) continue;

        const families = try self.proxy.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, gpa);
        defer gpa.free(families);
        for (families, 0..) |q, i| {
            if (q.queue_flags.graphics) {
                try list.append(gpa, .{ .pdev = pd, .queue_family = @intCast(i), .props = props });
                break;
            }
        }
    }

    std.mem.sort(Candidate, list.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.props.device_type == .discrete_gpu and b.props.device_type != .discrete_gpu;
        }
    }.lessThan);

    if (list.items.len == 0) return error.NoSuitableDevice;
    return list.toOwnedSlice(gpa);
}
