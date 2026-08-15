#include "dcse_apb3.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

static bool dcse_apb3_is_attached(const dcse_apb3_device_t *device)
{
    return (device != NULL) && (device->base != NULL);
}

/*
 * C11 atomic_signal_fence is a compiler barrier; it emits no atomic MMIO and
 * needs no runtime library.  A particular RV32/SoC port may additionally need
 * a RISC-V hardware fence and cache maintenance around DMA-visible buffers.
 */
static void dcse_apb3_compiler_barrier(void)
{
    atomic_signal_fence(memory_order_seq_cst);
}

static uint32_t dcse_apb3_read32(const dcse_apb3_device_t *device,
                                 uint32_t byte_offset)
{
    uint32_t value;

    if (!dcse_apb3_is_attached(device)) {
        return 0u;
    }

    dcse_apb3_compiler_barrier();
    value = device->base[byte_offset / sizeof(uint32_t)];
    dcse_apb3_compiler_barrier();
    return value;
}

static void dcse_apb3_write32(dcse_apb3_device_t *device,
                              uint32_t byte_offset,
                              uint32_t value)
{
    if (!dcse_apb3_is_attached(device)) {
        return;
    }

    dcse_apb3_compiler_barrier();
    device->base[byte_offset / sizeof(uint32_t)] = value;
    dcse_apb3_compiler_barrier();
}

static void dcse_apb3_write_address_pair(dcse_apb3_device_t *device,
                                         uint32_t low_offset,
                                         uint32_t high_offset,
                                         uint64_t address)
{
    const uint32_t low = (uint32_t)(address & UINT64_C(0xffffffff));
    const uint32_t high = (uint32_t)(address >> 32);

    /* Two native-width MMIO stores: suitable for RV32, but not atomic. */
    dcse_apb3_write32(device, low_offset, low);
    dcse_apb3_write32(device, high_offset, high);
}

bool dcse_apb3_attach(dcse_apb3_device_t *device,
                      volatile uint32_t *symbolic_base)
{
    if ((device == NULL) || (symbolic_base == NULL) ||
        (((uintptr_t)symbolic_base & (sizeof(uint32_t) - 1u)) != 0u)) {
        return false;
    }

    device->base = symbolic_base;
    return true;
}

uint32_t dcse_apb3_id(const dcse_apb3_device_t *device)
{
    return dcse_apb3_read32(device, DCSE_APB3_ID_OFFSET);
}

uint32_t dcse_apb3_version(const dcse_apb3_device_t *device)
{
    return dcse_apb3_read32(device, DCSE_APB3_VERSION_OFFSET);
}

uint32_t dcse_apb3_status(const dcse_apb3_device_t *device)
{
    return dcse_apb3_read32(device, DCSE_APB3_STATUS_OFFSET);
}

uint8_t dcse_apb3_error_code(const dcse_apb3_device_t *device)
{
    return (uint8_t)(dcse_apb3_read32(device,
                                      DCSE_APB3_ERROR_CODE_OFFSET) & 0xffu);
}

uint32_t dcse_apb3_start_count(const dcse_apb3_device_t *device)
{
    return dcse_apb3_read32(device, DCSE_APB3_START_COUNT_OFFSET);
}

uint32_t dcse_apb3_complete_count(const dcse_apb3_device_t *device)
{
    return dcse_apb3_read32(device, DCSE_APB3_COMPLETE_COUNT_OFFSET);
}

bool dcse_apb3_program_job(dcse_apb3_device_t *device,
                           const dcse_apb3_job_t *job)
{
    if (!dcse_apb3_is_attached(device) || (job == NULL) ||
        (job->layer_index >= DCSE_APB3_LAYER_COUNT)) {
        return false;
    }

    if (dcse_apb3_status_is_busy(dcse_apb3_status(device))) {
        return false;
    }

    dcse_apb3_write_address_pair(device,
                                 DCSE_APB3_INPUT_ADDR_LO_OFFSET,
                                 DCSE_APB3_INPUT_ADDR_HI_OFFSET,
                                 job->input_addr);
    dcse_apb3_write_address_pair(device,
                                 DCSE_APB3_WEIGHTS_ADDR_LO_OFFSET,
                                 DCSE_APB3_WEIGHTS_ADDR_HI_OFFSET,
                                 job->weights_addr);
    dcse_apb3_write_address_pair(device,
                                 DCSE_APB3_BIAS_ADDR_LO_OFFSET,
                                 DCSE_APB3_BIAS_ADDR_HI_OFFSET,
                                 job->bias_addr);
    dcse_apb3_write_address_pair(device,
                                 DCSE_APB3_DESC_ADDR_LO_OFFSET,
                                 DCSE_APB3_DESC_ADDR_HI_OFFSET,
                                 job->descriptor_addr);
    dcse_apb3_write_address_pair(device,
                                 DCSE_APB3_OUTPUT_ADDR_LO_OFFSET,
                                 DCSE_APB3_OUTPUT_ADDR_HI_OFFSET,
                                 job->output_addr);
    dcse_apb3_write32(device, DCSE_APB3_LAYER_INDEX_OFFSET,
                      job->layer_index);

    dcse_apb3_compiler_barrier();
    return true;
}

void dcse_apb3_set_irq_enable(dcse_apb3_device_t *device,
                              uint32_t irq_mask)
{
    dcse_apb3_write32(device, DCSE_APB3_IRQ_ENABLE_OFFSET,
                      irq_mask & DCSE_APB3_IRQ_ALL);
}

void dcse_apb3_ack_irq(dcse_apb3_device_t *device,
                       uint32_t irq_mask)
{
    dcse_apb3_write32(device, DCSE_APB3_IRQ_STATUS_OFFSET,
                      irq_mask & DCSE_APB3_IRQ_ALL);
}

bool dcse_apb3_try_start(dcse_apb3_device_t *device)
{
    uint32_t status;

    if (!dcse_apb3_is_attached(device)) {
        return false;
    }

    status = dcse_apb3_status(device);
    if (dcse_apb3_status_is_busy(status) ||
        !dcse_apb3_status_is_idle(status)) {
        return false;
    }

    /* Keep all prior configuration stores before the doorbell command. */
    dcse_apb3_compiler_barrier();
    dcse_apb3_write32(device, DCSE_APB3_CONTROL_OFFSET,
                      DCSE_APB3_CONTROL_START);
    return true;
}
