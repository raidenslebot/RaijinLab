using System;

namespace msclr
{
	// Token: 0x02000006 RID: 6
	internal struct _detail_class
	{
		// Token: 0x04000085 RID: 133
		public static string _safe_true = _detail_class.dummy_struct.dummy_string;

		// Token: 0x04000086 RID: 134
		public static string _safe_false = null;

		// Token: 0x02000007 RID: 7
		public struct dummy_struct
		{
			// Token: 0x04000087 RID: 135
			public static readonly string dummy_string = "";
		}
	}
}
