#include "dcse_apb3.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

enum {
    MOCK_REGISTER_WORDS = (DCSE_APB3_COMPLETE_COUNT_OFFSET / 4u) + 1u
};

static volatile uint32_t mock_registers[MOCK_REGISTER_WORDS];
static unsigned checks;
static unsigned failures;

#define CHECK(condition)                                                        \
    do {                                                                        \
        ++checks;                                                               \
        if (!(condition)) {                                                     \
            ++failures;                                                         \
            (void)fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
        }                                                                       \
    } while (false)

static unsigned word_index(uint32_t byte_offset)
{
    return (unsigned)(byte_offset / sizeof(uint32_t));
}

static void clear_mock(void)
{
    unsigned index;

    for (index = 0u; index < MOCK_REGISTER_WORDS; ++index) {
        mock_registers[index] = 0u;
    }
}

static void check_exact_register_map(void)
{
    CHECK(DCSE_APB3_ID_OFFSET == 0x00u);
    CHECK(DCSE_APB3_VERSION_OFFSET == 0x04u);
    CHECK(DCSE_APB3_CONTROL_OFFSET == 0x08u);
    CHECK(DCSE_APB3_STATUS_OFFSET == 0x0cu);
    CHECK(DCSE_APB3_IRQ_ENABLE_OFFSET == 0x10u);
    CHECK(DCSE_APB3_IRQ_STATUS_OFFSET == 0x14u);
    CHECK(DCSE_APB3_LAYER_INDEX_OFFSET == 0x18u);
    CHECK(DCSE_APB3_ERROR_CODE_OFFSET == 0x1cu);
    CHECK(DCSE_APB3_INPUT_ADDR_LO_OFFSET == 0x20u);
    CHECK(DCSE_APB3_INPUT_ADDR_HI_OFFSET == 0x24u);
    CHECK(DCSE_APB3_WEIGHTS_ADDR_LO_OFFSET == 0x28u);
    CHECK(DCSE_APB3_WEIGHTS_ADDR_HI_OFFSET == 0x2cu);
    CHECK(DCSE_APB3_BIAS_ADDR_LO_OFFSET == 0x30u);
    CHECK(DCSE_APB3_BIAS_ADDR_HI_OFFSET == 0x34u);
    CHECK(DCSE_APB3_DESC_ADDR_LO_OFFSET == 0x38u);
    CHECK(DCSE_APB3_DESC_ADDR_HI_OFFSET == 0x3cu);
    CHECK(DCSE_APB3_OUTPUT_ADDR_LO_OFFSET == 0x40u);
    CHECK(DCSE_APB3_OUTPUT_ADDR_HI_OFFSET == 0x44u);
    CHECK(DCSE_APB3_START_COUNT_OFFSET == 0x48u);
    CHECK(DCSE_APB3_COMPLETE_COUNT_OFFSET == 0x4cu);
}

static void check_identification_and_status(dcse_apb3_device_t *device)
{
    const uint32_t status = DCSE_APB3_STATUS_BUSY |
                            DCSE_APB3_STATUS_DONE |
                            DCSE_APB3_STATUS_ERROR |
                            DCSE_APB3_STATUS_IDLE |
                            DCSE_APB3_STATUS_IRQ_ACTIVE;

    mock_registers[word_index(DCSE_APB3_ID_OFFSET)] = UINT32_C(0x44435345);
    mock_registers[word_index(DCSE_APB3_VERSION_OFFSET)] = UINT32_C(0x00010000);
    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] = status;
    mock_registers[word_index(DCSE_APB3_ERROR_CODE_OFFSET)] =
        UINT32_C(0xdeadbe7a);
    mock_registers[word_index(DCSE_APB3_START_COUNT_OFFSET)] = 12u;
    mock_registers[word_index(DCSE_APB3_COMPLETE_COUNT_OFFSET)] = 9u;

    CHECK(dcse_apb3_id(device) == UINT32_C(0x44435345));
    CHECK(dcse_apb3_version(device) == UINT32_C(0x00010000));
    CHECK(dcse_apb3_status(device) == status);
    CHECK(dcse_apb3_status_is_busy(status));
    CHECK(dcse_apb3_status_is_done(status));
    CHECK(dcse_apb3_status_has_error(status));
    CHECK(dcse_apb3_status_is_idle(status));
    CHECK(dcse_apb3_status_irq_active(status));
    CHECK(dcse_apb3_error_code(device) == UINT8_C(0x7a));
    CHECK(dcse_apb3_start_count(device) == 12u);
    CHECK(dcse_apb3_complete_count(device) == 9u);

    CHECK(!dcse_apb3_status_is_busy(0u));
    CHECK(!dcse_apb3_status_is_done(0u));
    CHECK(!dcse_apb3_status_has_error(0u));
    CHECK(!dcse_apb3_status_is_idle(0u));
    CHECK(!dcse_apb3_status_irq_active(0u));
}

static void check_job_programming(dcse_apb3_device_t *device)
{
    const dcse_apb3_job_t job = {
        UINT64_C(0x0123456789abcdef),
        UINT64_C(0x1020304050607080),
        UINT64_C(0x8877665544332211),
        UINT64_C(0xa5a5a5a55a5a5a5a),
        UINT64_C(0xfedcba9876543210),
        34u
    };
    dcse_apb3_job_t invalid_job = job;

    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] = 0u;
    CHECK(dcse_apb3_program_job(device, &job));
    CHECK(mock_registers[word_index(DCSE_APB3_INPUT_ADDR_LO_OFFSET)] ==
          UINT32_C(0x89abcdef));
    CHECK(mock_registers[word_index(DCSE_APB3_INPUT_ADDR_HI_OFFSET)] ==
          UINT32_C(0x01234567));
    CHECK(mock_registers[word_index(DCSE_APB3_WEIGHTS_ADDR_LO_OFFSET)] ==
          UINT32_C(0x50607080));
    CHECK(mock_registers[word_index(DCSE_APB3_WEIGHTS_ADDR_HI_OFFSET)] ==
          UINT32_C(0x10203040));
    CHECK(mock_registers[word_index(DCSE_APB3_BIAS_ADDR_LO_OFFSET)] ==
          UINT32_C(0x44332211));
    CHECK(mock_registers[word_index(DCSE_APB3_BIAS_ADDR_HI_OFFSET)] ==
          UINT32_C(0x88776655));
    CHECK(mock_registers[word_index(DCSE_APB3_DESC_ADDR_LO_OFFSET)] ==
          UINT32_C(0x5a5a5a5a));
    CHECK(mock_registers[word_index(DCSE_APB3_DESC_ADDR_HI_OFFSET)] ==
          UINT32_C(0xa5a5a5a5));
    CHECK(mock_registers[word_index(DCSE_APB3_OUTPUT_ADDR_LO_OFFSET)] ==
          UINT32_C(0x76543210));
    CHECK(mock_registers[word_index(DCSE_APB3_OUTPUT_ADDR_HI_OFFSET)] ==
          UINT32_C(0xfedcba98));
    CHECK(mock_registers[word_index(DCSE_APB3_LAYER_INDEX_OFFSET)] == 34u);

    invalid_job.layer_index = DCSE_APB3_LAYER_COUNT;
    mock_registers[word_index(DCSE_APB3_LAYER_INDEX_OFFSET)] = 7u;
    CHECK(!dcse_apb3_program_job(device, &invalid_job));
    CHECK(mock_registers[word_index(DCSE_APB3_LAYER_INDEX_OFFSET)] == 7u);

    invalid_job.layer_index = 1u;
    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] =
        DCSE_APB3_STATUS_BUSY;
    CHECK(!dcse_apb3_program_job(device, &invalid_job));
    CHECK(mock_registers[word_index(DCSE_APB3_LAYER_INDEX_OFFSET)] == 7u);
    CHECK(!dcse_apb3_program_job(device, NULL));
}

static void check_interrupts_and_start(dcse_apb3_device_t *device)
{
    dcse_apb3_set_irq_enable(device, UINT32_C(0xffffffff));
    CHECK(mock_registers[word_index(DCSE_APB3_IRQ_ENABLE_OFFSET)] ==
          DCSE_APB3_IRQ_ALL);

    dcse_apb3_ack_irq(device, DCSE_APB3_IRQ_ERROR | UINT32_C(0x80));
    CHECK(mock_registers[word_index(DCSE_APB3_IRQ_STATUS_OFFSET)] ==
          DCSE_APB3_IRQ_ERROR);

    mock_registers[word_index(DCSE_APB3_CONTROL_OFFSET)] = 0u;
    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] =
        DCSE_APB3_STATUS_IDLE;
    CHECK(dcse_apb3_try_start(device));
    CHECK(mock_registers[word_index(DCSE_APB3_CONTROL_OFFSET)] ==
          DCSE_APB3_CONTROL_START);

    mock_registers[word_index(DCSE_APB3_CONTROL_OFFSET)] = 0u;
    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] =
        DCSE_APB3_STATUS_BUSY | DCSE_APB3_STATUS_IDLE;
    CHECK(!dcse_apb3_try_start(device));
    CHECK(mock_registers[word_index(DCSE_APB3_CONTROL_OFFSET)] == 0u);

    mock_registers[word_index(DCSE_APB3_STATUS_OFFSET)] = 0u;
    CHECK(!dcse_apb3_try_start(device));
    CHECK(mock_registers[word_index(DCSE_APB3_CONTROL_OFFSET)] == 0u);
}

int main(void)
{
    dcse_apb3_device_t device = { NULL };
    dcse_apb3_device_t invalid_device = { NULL };

    clear_mock();
    check_exact_register_map();

    CHECK(!dcse_apb3_attach(NULL, mock_registers));
    CHECK(!dcse_apb3_attach(&invalid_device, NULL));
    CHECK(dcse_apb3_attach(&device, mock_registers));

    check_identification_and_status(&device);
    check_job_programming(&device);
    check_interrupts_and_start(&device);

    CHECK(dcse_apb3_id(&invalid_device) == 0u);
    CHECK(!dcse_apb3_try_start(&invalid_device));

    if (failures != 0u) {
        (void)fprintf(stderr, "FAIL: %u of %u checks failed\n",
                      failures, checks);
        return 1;
    }

    (void)printf("PASS: dcse_apb3 host driver completed %u checks\n", checks);
    return 0;
}
