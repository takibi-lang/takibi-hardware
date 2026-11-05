/* riscv-arch-test target definitions for the takibi-hardware rv32 core
   (bench/arch_test). The core has no CSRs yet (issue #3), so tests run
   without the trap handler (rvtest_mtrap_routine is not defined); the test
   ends with EBREAK, which halts the core and the golden model, and the
   runner reads the signature between begin_signature and end_signature. */
#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_BOOT
#define RVMODEL_HALT ebreak;

#define RVMODEL_DATA_BEGIN \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END \
  .align 4; .global end_signature; end_signature:

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif
