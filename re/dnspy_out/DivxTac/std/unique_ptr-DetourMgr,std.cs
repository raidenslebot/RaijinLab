using System;
using System.Runtime.CompilerServices;

namespace std
{
	// Token: 0x02000068 RID: 104
	[NativeCppClass]
	internal struct unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>
	{
		// Token: 0x0600014E RID: 334 RVA: 0x0000486C File Offset: 0x00003C6C
		public unsafe static void <MarshalCopy>(unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>* A_0, unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>* A_1)
		{
			if (A_0 != null)
			{
				DetourMgr* ptr = *(int*)A_1;
				*(int*)A_1 = 0;
				*(int*)A_0 = ptr;
			}
		}

		// Token: 0x0600014F RID: 335 RVA: 0x000047DC File Offset: 0x00003BDC
		public unsafe static void <MarshalDestroy>(unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>* A_0)
		{
			<Module>.std.unique_ptr<DetourMgr,std::default_delete<DetourMgr>\u0020>.{dtor}(A_0);
		}
	}
}
