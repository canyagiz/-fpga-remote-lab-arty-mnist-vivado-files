/*
 * main.c -- UART image loader bridge for the MNIST CNN Arty Z7 lab.
 *
 * Runs on the Zynq PS (ARM Cortex-A9), fixed for every student -- it never
 * changes regardless of what the student's CNN datapath (PL) looks like.
 *
 * Job: receive one 784-byte MNIST image over UART0, write it into the BRAM
 * shared with the PL fabric (via the AXI BRAM Controller), then raise the
 * "image ready" bit on the shared AXI GPIO. The PL side (top_module.v)
 * copies the BRAM into fmap0 and runs inference when BTN1 is pressed, gated
 * on that ready bit.
 *
 * Repeats forever, one image per loop iteration.
 */

#include "xparameters.h"
#include "xuartps.h"
#include "xgpio.h"
#include "xil_io.h"

#define IMG_BYTES    784
#define GPIO_CHANNEL 1
#define UART_BAUD    115200

int main(void)
{
    XUartPs        uart;
    XUartPs_Config *uart_cfg;
    XGpio          gpio;
    int            i;
    u8             byte;

    uart_cfg = XUartPs_LookupConfig(XPAR_XUARTPS_0_BASEADDR);
    XUartPs_CfgInitialize(&uart, uart_cfg, uart_cfg->BaseAddress);
    XUartPs_SetBaudRate(&uart, UART_BAUD);

    XGpio_Initialize(&gpio, XPAR_AXI_GPIO_0_BASEADDR);
    XGpio_SetDataDirection(&gpio, GPIO_CHANNEL, 0x0);   /* all bits output */

    while (1) {
        XGpio_DiscreteWrite(&gpio, GPIO_CHANNEL, 0x0);  /* clear "ready" */

        for (i = 0; i < IMG_BYTES; i++) {
            byte = XUartPs_RecvByte(uart_cfg->BaseAddress);
            Xil_Out8(XPAR_AXI_BRAM_CTRL_0_BASEADDR + i, byte);
        }

        XGpio_DiscreteWrite(&gpio, GPIO_CHANNEL, 0x1);  /* signal "ready" */
    }

    return 0;
}
