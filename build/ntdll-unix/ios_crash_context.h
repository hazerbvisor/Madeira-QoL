/* Bounded, fault-safe diagnostics for the first unhandled bad access.
 * Never dereference guest memory directly or change the faulting context. */
static void ios_crash_context_line(int fd, const char *format, ...)
{
    va_list args, copy;
    va_start(args, format);
    if (fd >= 0)
    {
        va_copy(copy, args);
        vdprintf(fd, format, copy);
        va_end(copy);
    }
    dprintf(STDERR_FILENO, "[crash-context] ");
    vdprintf(STDERR_FILENO, format, args);
    va_end(args);
}

static void ios_crash_context_bytes(int fd, const char *name, uint64_t address, size_t length)
{
    unsigned char bytes[256];
    ios_crash_context_line(fd, "%s address=0x%llx length=%zu\n",
                           name, (unsigned long long)address, length);
    for (size_t offset = 0; offset < length; offset += sizeof(bytes))
    {
        mach_vm_size_t read = 0;
        size_t requested = length - offset;
        if (requested > sizeof(bytes)) requested = sizeof(bytes);
        if (address > UINT64_MAX - offset ||
            mach_vm_read_overwrite(mach_task_self(), address + offset, requested,
                                   (mach_vm_address_t)bytes, &read) != KERN_SUCCESS ||
            read != requested)
        {
            ios_crash_context_line(fd, "%s offset=0x%zx unreadable\n", name, offset);
            continue;
        }
        for (size_t index = 0; index < requested; index += 16)
        {
            char hex[49];
            size_t count = requested - index;
            if (count > 16) count = 16;
            for (size_t byte = 0; byte < count; byte++)
                snprintf(hex + byte * 3, sizeof(hex) - byte * 3, "%02x ", bytes[index + byte]);
            ios_crash_context_line(fd, "0x%llx: %s\n",
                                   (unsigned long long)(address + offset + index), hex);
        }
    }
}

static void ios_capture_crash_context(const arm_thread_state64_t *entry,
                                      const arm_thread_state64_t *current,
                                      uint64_t address, uint64_t kernel_code)
{
    /* The Mach server serializes these calls. Keep the first fault rather
     * than replacing its evidence with failures during exception dispatch. */
    static int captured;
    uint64_t pc = (uint64_t)__darwin_arm_thread_state64_get_pc(*entry);
    uint64_t page = pc & ~0xfffULL;
    const char *docs = getenv("MADEIRA_DOCS_DIR");
    char path[1024];
    int fd = -1;
    if (captured) return;
    captured = 1;
    if (docs && snprintf(path, sizeof(path), "%s/madeira-crash-context.txt", docs) < (int)sizeof(path))
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);

    ios_crash_context_line(fd, "snapshot-v1 pc=0x%llx fault=0x%llx kernel_code=%llu\n",
                           (unsigned long long)pc, (unsigned long long)address,
                           (unsigned long long)kernel_code);
    for (unsigned reg = 0; reg <= 31; reg++)
    {
        /* The access helper does not mutate state. Use a local copy to keep
         * its pointer API and this capture's const contract consistent. */
        arm_thread_state64_t before = *entry, after = *current;
        ios_crash_context_line(fd, "x%u entry=0x%llx after=0x%llx\n", reg,
                               (unsigned long long)IOS_ARM64_REG(before, reg),
                               (unsigned long long)IOS_ARM64_REG(after, reg));
    }
    ios_crash_context_line(fd, "cpsr=0x%x\n", entry->__cpsr);
    {
        uint32_t instruction = 0;
        mach_vm_size_t read = 0;
        if (mach_vm_read_overwrite(mach_task_self(), pc, sizeof(instruction),
                                   (mach_vm_address_t)&instruction, &read) == KERN_SUCCESS &&
            read == sizeof(instruction) && (instruction & 0x3ffffc00) == 0x089ffc00)
        {
            unsigned reg = (instruction >> 5) & 31;
            arm_thread_state64_t before = *entry;
            ios_crash_context_line(fd, "stlr insn=0x%08x base=x%u entry_address=0x%llx\n",
                                   instruction, reg,
                                   (unsigned long long)IOS_ARM64_REG(before, reg));
        }
    }
    /* At most 20 KiB of code and 1.25 KiB of state, encoded as plain text.
     * Include preceding blocks to investigate unexpected entry/return PCs. */
    ios_crash_context_bytes(fd, "host-code", page >= 0x4000 ? page - 0x4000 : 0, 0x5000);
    ios_crash_context_bytes(fd, "fex-state-x28", entry->__x[28], 1024);
    ios_crash_context_bytes(fd, "guest-stack-x23", entry->__x[23], 256);
    if (fd >= 0)
    {
        close(fd);
        dprintf(STDERR_FILENO, "[crash-context] saved %s; this snapshot is also in madeira-log.txt\n", path);
    }
    else
        dprintf(STDERR_FILENO, "[crash-context] file unavailable; snapshot included in madeira-log.txt\n");
}
