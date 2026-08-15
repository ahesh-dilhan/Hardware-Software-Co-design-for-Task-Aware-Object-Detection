#ifndef DCSE_APB3_H
#define DCSE_APB3_H

/*
 * Portable software view of the dcse_apb3_ctrl register contract.
 *
 * This is deliberately not a VEGA board driver: the caller supplies the
 * symbolic MMIO base after the SoC integrator assigns an address.  Cache
 * maintenance, physical-address translation, hardware I/O fences, interrupt
 * routing, and mutual exclusion remain platform responsibilities.
 */

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum dcse_apb3_register_offset {
    DCSE_APB3_ID_OFFSET              = 0x00u,
    DCSE_APB3_VERSION_OFFSET         = 0x04u,
    DCSE_APB3_CONTROL_OFFSET         = 0x08u,
    DCSE_APB3_STATUS_OFFSET          = 0x0cu,
    DCSE_APB3_IRQ_ENABLE_OFFSET      = 0x10u,
    DCSE_APB3_IRQ_STATUS_OFFSET      = 0x14u,
    DCSE_APB3_LAYER_INDEX_OFFSET     = 0x18u,
    DCSE_APB3_ERROR_CODE_OFFSET      = 0x1cu,
    DCSE_APB3_INPUT_ADDR_LO_OFFSET   = 0x20u,
    DCSE_APB3_INPUT_ADDR_HI_OFFSET   = 0x24u,
    DCSE_APB3_WEIGHTS_ADDR_LO_OFFSET = 0x28u,
    DCSE_APB3_WEIGHTS_ADDR_HI_OFFSET = 0x2cu,
    DCSE_APB3_BIAS_ADDR_LO_OFFSET    = 0x30u,
    DCSE_APB3_BIAS_ADDR_HI_OFFSET    = 0x34u,
    DCSE_APB3_DESC_ADDR_LO_OFFSET    = 0x38u,
    DCSE_APB3_DESC_ADDR_HI_OFFSET    = 0x3cu,
    DCSE_APB3_OUTPUT_ADDR_LO_OFFSET  = 0x40u,
    DCSE_APB3_OUTPUT_ADDR_HI_OFFSET  = 0x44u,
    DCSE_APB3_START_COUNT_OFFSET     = 0x48u,
    DCSE_APB3_COMPLETE_COUNT_OFFSET  = 0x4cu
};

enum dcse_apb3_control_bits {
    DCSE_APB3_CONTROL_START = UINT32_C(1) << 0
};

enum dcse_apb3_status_bits {
    DCSE_APB3_STATUS_BUSY       = UINT32_C(1) << 0,
    DCSE_APB3_STATUS_DONE       = UINT32_C(1) << 1,
    DCSE_APB3_STATUS_ERROR      = UINT32_C(1) << 2,
    DCSE_APB3_STATUS_IDLE       = UINT32_C(1) << 3,
    DCSE_APB3_STATUS_IRQ_ACTIVE = UINT32_C(1) << 4
};

enum dcse_apb3_irq_bits {
    DCSE_APB3_IRQ_DONE  = UINT32_C(1) << 0,
    DCSE_APB3_IRQ_ERROR = UINT32_C(1) << 1,
    DCSE_APB3_IRQ_ALL   = DCSE_APB3_IRQ_DONE | DCSE_APB3_IRQ_ERROR
};

enum {
    DCSE_APB3_LAYER_COUNT = 35u
};

typedef struct dcse_apb3_device {
    volatile uint32_t *base;
} dcse_apb3_device_t;

typedef struct dcse_apb3_job {
    uint64_t input_addr;
    uint64_t weights_addr;
    uint64_t bias_addr;
    uint64_t descriptor_addr;
    uint64_t output_addr;
    uint32_t layer_index;
} dcse_apb3_job_t;

/* Attach the register-contract driver to a caller-supplied, aligned base. */
bool dcse_apb3_attach(dcse_apb3_device_t *device,
                      volatile uint32_t *symbolic_base);

uint32_t dcse_apb3_id(const dcse_apb3_device_t *device);
uint32_t dcse_apb3_version(const dcse_apb3_device_t *device);
uint32_t dcse_apb3_status(const dcse_apb3_device_t *device);
uint8_t dcse_apb3_error_code(const dcse_apb3_device_t *device);
uint32_t dcse_apb3_start_count(const dcse_apb3_device_t *device);
uint32_t dcse_apb3_complete_count(const dcse_apb3_device_t *device);

/*
 * Program both RV32-sized halves of every 64-bit address, then the layer.
 * The function rejects an invalid layer or an already-busy device.  The
 * caller must serialize programming against other software contexts.
 */
bool dcse_apb3_program_job(dcse_apb3_device_t *device,
                           const dcse_apb3_job_t *job);

/* Enable only the two interrupt causes implemented by the RTL contract. */
void dcse_apb3_set_irq_enable(dcse_apb3_device_t *device,
                              uint32_t irq_mask);

/* Acknowledge selected sticky causes with the RTL's write-one-to-clear rule. */
void dcse_apb3_ack_irq(dcse_apb3_device_t *device,
                       uint32_t irq_mask);

/*
 * Start only after a status snapshot reports !BUSY && IDLE.  A true return
 * means that the MMIO command was issued; it cannot report a platform bus
 * fault and is not a substitute for sole ownership or a driver lock.
 */
bool dcse_apb3_try_start(dcse_apb3_device_t *device);

static inline bool dcse_apb3_status_is_busy(uint32_t status)
{
    return (status & DCSE_APB3_STATUS_BUSY) != 0u;
}

static inline bool dcse_apb3_status_is_done(uint32_t status)
{
    return (status & DCSE_APB3_STATUS_DONE) != 0u;
}

static inline bool dcse_apb3_status_has_error(uint32_t status)
{
    return (status & DCSE_APB3_STATUS_ERROR) != 0u;
}

static inline bool dcse_apb3_status_is_idle(uint32_t status)
{
    return (status & DCSE_APB3_STATUS_IDLE) != 0u;
}

static inline bool dcse_apb3_status_irq_active(uint32_t status)
{
    return (status & DCSE_APB3_STATUS_IRQ_ACTIVE) != 0u;
}

#ifdef __cplusplus
}
#endif

#endif
