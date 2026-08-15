const r4os = @import("r4os");
const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    net: r4os.r4net.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }
};

const category_count: usize = 10;
const chart_size: u32 = 128;
const chart_pixels: usize = chart_size * chart_size;
const mb: u64 = 1024 * 1024;
const kb: u64 = 1024;

const cat_kernel: usize = 0;
const cat_apps: usize = 1;
const cat_stacks: usize = 2;
const cat_heaps: usize = 3;
const cat_program_images: usize = 4;
const cat_dma: usize = 5;
const cat_mmio: usize = 6;
const cat_page_tables: usize = 7;
const cat_reserves: usize = 8;
const cat_free: usize = 9;

const bg: u32 = 0xD8D0C8;
const panel: u32 = 0xF0F0F0;
const text: u32 = 0x000000;
const muted: u32 = 0x606060;
const border: u32 = 0x404040;
const title_bg: u32 = 0x0A246A;
const title_text: u32 = 0xFFFFFF;

const CategoryStats = struct {
    bytes: u64 = 0,
    blocks: u32 = 0,
};

const CategorySet = struct {
    categories: [category_count]CategoryStats = .{CategoryStats{}} ** category_count,
    total: u64 = 0,
    overflow: bool = false,

    fn add(self: *CategorySet, category: usize, value: u64) void {
        if (category >= category_count or value == 0) return;
        const current_total = self.total;
        self.total +%= value;
        if (self.total < current_total) self.overflow = true;
        const current_cat = self.categories[category].bytes;
        self.categories[category].bytes +%= value;
        if (self.categories[category].bytes < current_cat) self.overflow = true;
        self.categories[category].blocks +%= 1;
    }
};

const Snapshot = struct {
    physical_ram: CategorySet = .{},
    virtual_reserved: CategorySet = .{},
    committed_virtual: CategorySet = .{},
    block_count: u32 = 0,
    largest_free_phys: u64 = 0,
    largest_free_virt: u64 = 0,
    ram_ceiling: u64 = 0,
    non_ram_physical: u64 = 0,
    overflow: bool = false,
    paging_available: bool = false,
    paging_r4os_active: bool = false,
    paging_cr3_match: bool = false,
    paging_root: u64 = 0,
    paging_hardware_cr3: u64 = 0,
    page_table_blocks: u64 = 0,
    kernel_page_table_blocks: u64 = 0,
    bootloader_page_table_blocks: u64 = 0,
    limine_quarantined_frames: u64 = 0,
    limine_released_frames: u64 = 0,
    limine_retained_frames: u64 = 0,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 640,
    h: i32 = 420,
    snapshot: Snapshot = .{},
    pie_pixels: [chart_pixels]u32 = .{0} ** chart_pixels,

    fn run(self: *App) i32 {
        if (argsContain(self.ctx.sys.argsRaw(), "/SELFTEST") or argsContain(self.ctx.sys.argsRaw(), "SELFTEST")) {
            return self.runSelfTest();
        }
        if (self.ctx.desk.programWindowId() < 0) {
            self.ctx.sys.println("MemView");
            self.ctx.sys.println("Please start from Desktop as a GUI app or use /SELFTEST.");
            return 0;
        }
        return self.runHosted();
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("MemView");
        _ = self.ctx.desk.guiSetMinSize(620, 360);
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        self.updateMetrics(info);
        self.render();

        var frame: u32 = 0;
        while (!self.ctx.sys.programShouldClose()) {
            var dirty = false;
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        _ = self.ctx.desk.guiWindowInfo(&info);
                        self.updateMetrics(info);
                        dirty = true;
                    },
                    .key_down => {
                        const key: u8 = @intCast(event.key & 0xFF);
                        if (key == r4os.gui.Key.escape) return 0;
                        if (key == 'r' or key == 'R') dirty = true;
                    },
                    else => {},
                }
            }
            if (dirty or frame == 0) self.render();
            frame +%= 1;
            if (frame >= 35) frame = 0;
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn updateMetrics(self: *App, info: r4os.abi.GuiWindowInfo) void {
        self.w = clampI32(info.client_w, 420, 1600);
        self.h = clampI32(info.client_h, 280, 1000);
    }

    fn runSelfTest(self: *App) i32 {
        var ok = true;
        self.ctx.sys.println("MEMVIEW selftest");

        self.ctx.sys.print("chart helper: ");
        const chart_ok = r4os.chart.validateChartHelpers();
        self.ctx.sys.println(if (chart_ok) "ok" else "FAILED");
        ok = chart_ok and ok;

        self.ctx.sys.print("synthetic snapshot: ");
        var synthetic = Snapshot{};
        synthetic.physical_ram.add(cat_kernel, 8 * mb);
        synthetic.physical_ram.add(cat_heaps, 4 * mb);
        synthetic.physical_ram.add(cat_reserves, 4 * mb);
        synthetic.physical_ram.add(cat_free, 32 * mb);
        synthetic.virtual_reserved.add(cat_heaps, 128 * mb);
        synthetic.virtual_reserved.add(cat_stacks, 8 * mb);
        synthetic.committed_virtual.add(cat_heaps, 4 * mb);
        synthetic.committed_virtual.add(cat_stacks, 64 * kb);
        const synthetic_ok = validateSnapshot(synthetic);
        self.ctx.sys.println(if (synthetic_ok) "ok" else "FAILED");
        ok = synthetic_ok and ok;

        self.ctx.sys.print("sum mismatch detection: ");
        var bad_sum = synthetic;
        bad_sum.physical_ram.total += 1;
        const sum_ok = !validateSnapshot(bad_sum);
        self.ctx.sys.println(if (sum_ok) "ok" else "FAILED");
        ok = sum_ok and ok;

        self.ctx.sys.print("empty category detection: ");
        const empty_ok = !validateSnapshot(Snapshot{});
        self.ctx.sys.println(if (empty_ok) "ok" else "FAILED");
        ok = empty_ok and ok;

        self.ctx.sys.print("runtime snapshot: ");
        if (self.refreshSnapshot() and validateSnapshot(self.snapshot)) {
            self.ctx.sys.write("ok blocks=");
            self.ctx.sys.printU64(self.snapshot.block_count);
            self.ctx.sys.write(" ramMB=");
            self.ctx.sys.printU64(self.snapshot.physical_ram.total / mb);
            self.ctx.sys.write(" virtMB=");
            self.ctx.sys.printU64(self.snapshot.virtual_reserved.total / mb);
            self.ctx.sys.write(" paging=");
            const paging_ok = self.snapshot.paging_available and self.snapshot.paging_r4os_active and self.snapshot.paging_cr3_match;
            self.ctx.sys.write(if (paging_ok) "ok" else "FAILED");
            self.ctx.sys.write(" pt=");
            self.ctx.sys.printU64(self.snapshot.page_table_blocks);
            self.ctx.sys.println("");
            ok = paging_ok and ok;
        } else {
            self.ctx.sys.println("FAILED");
            ok = false;
        }

        self.ctx.sys.println(if (ok) "MEMVIEW selftest: OK" else "MEMVIEW selftest: FAILED");
        return if (ok) 0 else 1;
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        _ = canvas.clear(bg);
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = 26 }, title_bg);
        _ = canvas.text(10, 9, "MemView", title_text, title_bg);

        if (!self.refreshSnapshot()) {
            _ = canvas.text(16, 48, "Memory snapshot unavailable.", text, bg);
            _ = paint.present();
            return;
        }

        const main_scale: u32 = if (self.w >= 820 and self.h >= 560) 2 else 1;
        const main_size: i32 = @as(i32, @intCast(chart_size)) * @as(i32, @intCast(main_scale));
        const pie_x: i32 = 18;
        const pie_y: i32 = 48;

        var line: [112]u8 = .{0} ** 112;
        var scratch: [112]u8 = .{0} ** 112;

        _ = canvas.text(pie_x, 34, "Physischer RAM", text, bg);
        self.drawPieSet(canvas, &self.snapshot.physical_ram, pie_x, pie_y, main_scale);
        _ = canvas.text(pie_x, pie_y + main_size + 14, formatSummary(line[0..], "RAM total", self.snapshot.physical_ram.total), text, bg);
        _ = canvas.text(pie_x, pie_y + main_size + 28, formatSummary(scratch[0..], "RAM frei", self.snapshot.physical_ram.categories[cat_free].bytes), text, bg);

        const legend_x = pie_x + main_size + 24;
        var legend_y: i32 = 44;
        _ = canvas.text(legend_x, legend_y, "RAM-Aufteilung", text, bg);
        legend_y += 18;
        self.drawLegend(canvas, &self.snapshot.physical_ram, legend_x, &legend_y, true);

        if (self.w >= 600 and self.h >= 400) {
            const mini_y = self.h - 198;
            const left_x: i32 = 18;
            const right_x: i32 = @max(320, @divTrunc(self.w, 2) + 8);
            self.drawCompactView(canvas, "Virtuell reserviert", &self.snapshot.virtual_reserved, left_x, mini_y);
            self.drawCompactView(canvas, "Committed virtuell", &self.snapshot.committed_virtual, right_x, mini_y);
        }

        const footer_y = self.h - 66;
        _ = canvas.rect(.{ .x = 0, .y = footer_y - 8, .w = self.w, .h = self.h - footer_y + 8 }, 0xC8C0B8);
        _ = canvas.text(16, footer_y, formatBlocksAndOther(line[0..], self.snapshot.block_count, self.snapshot.non_ram_physical), muted, 0xC8C0B8);
        _ = canvas.text(16, footer_y + 16, formatSummary(scratch[0..], "Largest phys", self.snapshot.largest_free_phys), muted, 0xC8C0B8);
        _ = canvas.text(16, footer_y + 32, formatSummary(line[0..], "Largest virt", self.snapshot.largest_free_virt), muted, 0xC8C0B8);
        _ = canvas.text(16, footer_y + 48, formatPaging(scratch[0..], &self.snapshot), muted, 0xC8C0B8);
        _ = paint.present();
    }

    fn refreshSnapshot(self: *App) bool {
        self.snapshot = .{};
        const summary = self.ctx.dev.memorySummary() orelse return false;
        self.snapshot.block_count = self.ctx.dev.memoryBlockCount();
        self.snapshot.largest_free_phys = summary.largest_free_phys_len;
        self.snapshot.largest_free_virt = summary.largest_free_virtual_len;
        self.snapshot.overflow = summary.overflow != 0;
        self.snapshot.ram_ceiling = self.detectRamCeiling();

        var index: u32 = 0;
        while (index < self.snapshot.block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.status == r4os.abi.memory_status_released) continue;
            self.addPhysicalBlock(block);
            self.addVirtualBlock(block);
        }
        if (self.snapshot.physical_ram.categories[cat_free].bytes == 0 and summary.free_physical_bytes != 0) {
            self.snapshot.physical_ram.add(cat_free, summary.free_physical_bytes);
        }
        if (self.snapshot.ram_ceiling <= 0x8000_0000 and self.snapshot.ram_ceiling > self.snapshot.physical_ram.total) {
            self.snapshot.physical_ram.add(cat_reserves, self.snapshot.ram_ceiling - self.snapshot.physical_ram.total);
        }
        if (self.ctx.dev.pagingSummary()) |paging| {
            self.snapshot.paging_available = true;
            self.snapshot.paging_r4os_active = (paging.flags & r4os.abi.paging_flag_r4os_root_active) != 0;
            self.snapshot.paging_cr3_match = (paging.flags & r4os.abi.paging_flag_active_root_matches_hardware) != 0;
            self.snapshot.paging_root = paging.active_root_phys;
            self.snapshot.paging_hardware_cr3 = paging.hardware_cr3;
            self.snapshot.page_table_blocks = paging.page_table_blocks;
            self.snapshot.kernel_page_table_blocks = paging.kernel_page_table_blocks;
            self.snapshot.bootloader_page_table_blocks = paging.bootloader_page_table_blocks;
            self.snapshot.limine_quarantined_frames = paging.limine_quarantined_frames;
            self.snapshot.limine_released_frames = paging.limine_released_frames;
            self.snapshot.limine_retained_frames = paging.limine_retained_frames;
        }
        return self.snapshot.physical_ram.total != 0;
    }

    fn detectRamCeiling(self: *App) u64 {
        var ceiling: u64 = 0;
        var index: u32 = 0;
        while (index < self.snapshot.block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.status == r4os.abi.memory_status_released or block.phys_len == 0) continue;
            if (!isRamPhysicalBlock(block, ~@as(u64, 0))) continue;
            const end = block.phys_base +% block.phys_len;
            if (end > block.phys_base and end > ceiling) ceiling = end;
        }
        return ceiling;
    }

    fn addPhysicalBlock(self: *App, block: r4os.abi.ProgramMemoryBlockInfo) void {
        if (block.phys_len == 0) return;
        if (!isRamPhysicalBlock(block, self.snapshot.ram_ceiling)) {
            self.snapshot.non_ram_physical +%= block.phys_len;
            if (self.snapshot.non_ram_physical < block.phys_len) self.snapshot.overflow = true;
            return;
        }
        self.snapshot.physical_ram.add(categoryForBlock(block), block.phys_len);
    }

    fn addVirtualBlock(self: *App, block: r4os.abi.ProgramMemoryBlockInfo) void {
        if (block.virt_len == 0) return;
        const category = categoryForBlock(block);
        self.snapshot.virtual_reserved.add(category, block.virt_len);
        if (block.committed_bytes != 0) self.snapshot.committed_virtual.add(category, block.committed_bytes);
    }

    fn drawPieSet(self: *App, canvas: r4os.gui.Canvas, set: *const CategorySet, x: i32, y: i32, scale: u32) void {
        const draw_size: i32 = @as(i32, @intCast(chart_size)) * @as(i32, @intCast(scale));
        _ = canvas.rect(.{ .x = x - 2, .y = y - 2, .w = draw_size + 4, .h = draw_size + 4 }, panel);
        if (set.total == 0) return;

        var slices: [category_count]r4os.chart.PieSlice = .{r4os.chart.PieSlice{}} ** category_count;
        const slice_count = buildSlices(set, slices[0..]);
        var segments: [category_count]r4os.chart.PieSegment = .{r4os.chart.PieSegment{}} ** category_count;
        if (slice_count > 0) {
            if (r4os.chart.buildPieSegments(slices[0..slice_count], segments[0..])) |_| {
                r4os.chart.drawPie(self.pie_pixels[0..], chart_size, chart_size, segments[0..slice_count], panel, border) catch {};
                _ = canvas.raster(x, y, chart_size, chart_size, scale, self.pie_pixels[0..]);
            } else |_| {}
        }
    }

    fn drawCompactView(self: *App, canvas: r4os.gui.Canvas, title_value: [*:0]const u8, set: *const CategorySet, x: i32, y: i32) void {
        var line: [112]u8 = .{0} ** 112;
        _ = canvas.text(x, y, title_value, text, bg);
        self.drawPieSet(canvas, set, x, y + 18, 1);
        const text_x = x + 140;
        var text_y = y + 22;
        _ = canvas.text(text_x, text_y, formatSummary(line[0..], "Total", set.total), text, bg);
        text_y += 17;
        self.drawLegendLimited(canvas, set, text_x, &text_y, 4);
    }

    fn drawLegend(self: *App, canvas: r4os.gui.Canvas, set: *const CategorySet, x: i32, y: *i32, include_blocks: bool) void {
        _ = self;
        var line: [112]u8 = .{0} ** 112;
        var i: usize = 0;
        while (i < category_count) : (i += 1) {
            const cat = set.categories[i];
            if (cat.bytes == 0) continue;
            _ = canvas.rect(.{ .x = x, .y = y.* + 3, .w = 11, .h = 11 }, categoryColor(i));
            const label = if (include_blocks) formatCategory(line[0..], i, cat) else formatCategoryCompact(line[0..], i, cat);
            _ = canvas.text(x + 18, y.*, label, text, bg);
            y.* += 17;
        }
    }

    fn drawLegendLimited(self: *App, canvas: r4os.gui.Canvas, set: *const CategorySet, x: i32, y: *i32, limit: usize) void {
        _ = self;
        var line: [112]u8 = .{0} ** 112;
        var shown: usize = 0;
        var i: usize = 0;
        while (i < category_count and shown < limit) : (i += 1) {
            const cat = set.categories[i];
            if (cat.bytes == 0) continue;
            _ = canvas.rect(.{ .x = x, .y = y.* + 3, .w = 11, .h = 11 }, categoryColor(i));
            _ = canvas.text(x + 18, y.*, formatCategoryCompact(line[0..], i, cat), text, bg);
            y.* += 17;
            shown += 1;
        }
    }
};

fn validateSnapshot(snapshot: Snapshot) bool {
    if (snapshot.overflow) return false;
    return validateSet(snapshot.physical_ram, false) and
        validateSet(snapshot.virtual_reserved, true) and
        validateSet(snapshot.committed_virtual, true);
}

fn validateSet(set: CategorySet, allow_empty: bool) bool {
    if (set.overflow) return false;
    if (set.total == 0) return allow_empty;
    var sum: u64 = 0;
    var visible: usize = 0;
    var i: usize = 0;
    while (i < category_count) : (i += 1) {
        const bytes = set.categories[i].bytes;
        if (bytes == 0) continue;
        visible += 1;
        if (sum > ~@as(u64, 0) - bytes) return false;
        sum += bytes;
    }
    return visible > 0 and sum == set.total;
}

fn buildSlices(set: *const CategorySet, out: []r4os.chart.PieSlice) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < category_count and count < out.len) : (i += 1) {
        const cat = set.categories[i];
        if (cat.bytes == 0) continue;
        out[count] = .{ .value = cat.bytes, .color = categoryColor(i) };
        count += 1;
    }
    return count;
}

fn isRamPhysicalBlock(block: r4os.abi.ProgramMemoryBlockInfo, ram_ceiling: u64) bool {
    if (block.kind == r4os.abi.memory_kind_mmio or block.kind == r4os.abi.memory_kind_framebuffer) return false;
    if (block.owner == r4os.abi.memory_owner_device) return false;
    if (block.phys_base >= 0x8000_0000 and isFirmwareLikeBlock(block)) return false;
    const end = block.phys_base +% block.phys_len;
    return end > block.phys_base and end <= ram_ceiling;
}

fn isFirmwareLikeBlock(block: r4os.abi.ProgramMemoryBlockInfo) bool {
    return block.kind == r4os.abi.memory_kind_reserved or
        block.kind == r4os.abi.memory_kind_unknown or
        block.kind == r4os.abi.memory_kind_boot;
}

fn categoryForBlock(block: r4os.abi.ProgramMemoryBlockInfo) usize {
    if (block.kind == r4os.abi.memory_kind_dma) return cat_dma;
    if (block.kind == r4os.abi.memory_kind_mmio) return cat_mmio;
    if (block.owner == r4os.abi.memory_owner_r4x_instance and
        block.kind != r4os.abi.memory_kind_program_image and
        block.kind != r4os.abi.memory_kind_app_heap and
        block.kind != r4os.abi.memory_kind_app_stack)
    {
        return cat_apps;
    }
    return switch (block.kind) {
        r4os.abi.memory_kind_kernel => cat_kernel,
        r4os.abi.memory_kind_kernel_heap, r4os.abi.memory_kind_app_heap => cat_heaps,
        r4os.abi.memory_kind_page_table => cat_page_tables,
        r4os.abi.memory_kind_program_image => cat_program_images,
        r4os.abi.memory_kind_app_stack => cat_stacks,
        r4os.abi.memory_kind_dma => cat_dma,
        r4os.abi.memory_kind_mmio => cat_mmio,
        r4os.abi.memory_kind_free => cat_free,
        else => cat_reserves,
    };
}

fn categoryColor(index: usize) u32 {
    return switch (index) {
        cat_kernel => 0x0A246A,
        cat_apps => 0x008080,
        cat_stacks => 0x800000,
        cat_heaps => 0x008000,
        cat_program_images => 0x808000,
        cat_dma => 0x800080,
        cat_mmio => 0x606060,
        cat_page_tables => 0x000080,
        cat_reserves => 0xB0B0B0,
        cat_free => 0x00A000,
        else => 0x404040,
    };
}

fn categoryLabel(index: usize) []const u8 {
    return switch (index) {
        cat_kernel => "Kernel",
        cat_apps => "Apps",
        cat_stacks => "Stacks",
        cat_heaps => "Heaps",
        cat_program_images => "ProgramImages",
        cat_dma => "DMA",
        cat_mmio => "MMIO",
        cat_page_tables => "PageTables",
        cat_reserves => "Reserved/Firmware",
        cat_free => "Free",
        else => "Unknown",
    };
}

fn formatCategory(out: []u8, index: usize, cat: CategoryStats) [*:0]const u8 {
    var writer = BufferWriter.init(out);
    writer.append(categoryLabel(index));
    writer.append(": ");
    writer.appendSize(cat.bytes);
    writer.append("  ");
    writer.appendU64(cat.blocks);
    writer.append(" blk");
    return writer.finish();
}

fn formatCategoryCompact(out: []u8, index: usize, cat: CategoryStats) [*:0]const u8 {
    var writer = BufferWriter.init(out);
    writer.append(categoryLabel(index));
    writer.append(": ");
    writer.appendSize(cat.bytes);
    return writer.finish();
}

fn formatSummary(out: []u8, label: []const u8, bytes: u64) [*:0]const u8 {
    var writer = BufferWriter.init(out);
    writer.append(label);
    writer.append(": ");
    writer.appendSize(bytes);
    return writer.finish();
}

fn formatBlocksAndOther(out: []u8, blocks: u32, other_phys: u64) [*:0]const u8 {
    var writer = BufferWriter.init(out);
    writer.append("MemoryBlocks: ");
    writer.appendU64(blocks);
    writer.append("  Device phys: ");
    writer.appendSize(other_phys);
    return writer.finish();
}

fn formatPaging(out: []u8, snapshot: *const Snapshot) [*:0]const u8 {
    var writer = BufferWriter.init(out);
    writer.append("Paging: ");
    if (!snapshot.paging_available) {
        writer.append("not available");
        return writer.finish();
    }
    writer.append(if (snapshot.paging_r4os_active) "R4OS PML4" else "not R4OS");
    writer.append(", CR3 ");
    writer.append(if (snapshot.paging_cr3_match) "match" else "mismatch");
    writer.append(", PT ");
    writer.appendU64(snapshot.page_table_blocks);
    writer.append(" blocks, Limine q=");
    writer.appendU64(snapshot.limine_quarantined_frames);
    return writer.finish();
}

const BufferWriter = struct {
    buffer: []u8,
    len: usize = 0,

    fn init(buffer: []u8) BufferWriter {
        if (buffer.len > 0) buffer[0] = 0;
        return .{ .buffer = buffer };
    }

    fn append(self: *BufferWriter, text_value: []const u8) void {
        var i: usize = 0;
        while (i < text_value.len and self.len + 1 < self.buffer.len) : (i += 1) {
            self.buffer[self.len] = text_value[i];
            self.len += 1;
        }
        if (self.buffer.len > 0) self.buffer[self.len] = 0;
    }

    fn appendU64(self: *BufferWriter, value: u64) void {
        var temp: [20]u8 = undefined;
        var pos = temp.len;
        var n = value;
        if (n == 0) {
            self.append("0");
            return;
        }
        while (n > 0 and pos > 0) {
            pos -= 1;
            temp[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.append(temp[pos..]);
    }

    fn appendSize(self: *BufferWriter, bytes: u64) void {
        if (bytes >= mb) {
            self.appendU64(bytes / mb);
            self.append(" MB");
        } else if (bytes >= kb) {
            self.appendU64((bytes + kb - 1) / kb);
            self.append(" KB");
        } else {
            self.appendU64(bytes);
            self.append(" B");
        }
    }

    fn finish(self: *BufferWriter) [*:0]const u8 {
        if (self.buffer.len == 0) return "";
        self.buffer[self.len] = 0;
        return @ptrCast(self.buffer.ptr);
    }
};

fn argsContain(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (args[offset] != 0) {
        while (args[offset] == ' ' or args[offset] == '\t') : (offset += 1) {}
        if (args[offset] == 0) break;
        const start = offset;
        while (args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}
