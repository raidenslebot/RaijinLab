using System;
using System.Runtime.CompilerServices;

namespace std
{
	// Token: 0x02000023 RID: 35
	[NativeCppClass]
	internal struct shared_ptr<ProcessDescription>
	{
		// Token: 0x0600014A RID: 330 RVA: 0x00001B78 File Offset: 0x00000F78
		public unsafe static void <MarshalCopy>(shared_ptr<ProcessDescription>* A_0, shared_ptr<ProcessDescription>* A_1)
		{
			if (A_0 != null)
			{
				<Module>.std._Ptr_base<ProcessDescription>.{ctor}(A_0);
				*(int*)A_0 = *(int*)A_1;
				*(int*)(A_0 + 4 / sizeof(shared_ptr<ProcessDescription>)) = *(int*)(A_1 + 4 / sizeof(shared_ptr<ProcessDescription>));
				*(int*)A_1 = 0;
				*(int*)(A_1 + 4 / sizeof(shared_ptr<ProcessDescription>)) = 0;
			}
		}

		// Token: 0x0600014B RID: 331 RVA: 0x00002474 File Offset: 0x00001874
		public unsafe static void <MarshalDestroy>(shared_ptr<ProcessDescription>* A_0)
		{
			uint num = (uint)(*(int*)(A_0 + 4 / sizeof(shared_ptr<ProcessDescription>)));
			if (num != 0U)
			{
				<Module>.std._Ref_count_base._Decref(num);
			}
		}
	}
}
