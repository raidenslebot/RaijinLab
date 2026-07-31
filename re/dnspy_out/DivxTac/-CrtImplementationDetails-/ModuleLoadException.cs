using System;
using System.Runtime.Serialization;

namespace <CrtImplementationDetails>
{
	// Token: 0x02000072 RID: 114
	[Serializable]
	internal class ModuleLoadException : Exception
	{
		// Token: 0x06000150 RID: 336 RVA: 0x00006EA4 File Offset: 0x000062A4
		protected ModuleLoadException(SerializationInfo info, StreamingContext context)
			: base(info, context)
		{
		}

		// Token: 0x06000151 RID: 337 RVA: 0x00006E8C File Offset: 0x0000628C
		public ModuleLoadException(string message, Exception innerException)
			: base(message, innerException)
		{
		}

		// Token: 0x06000152 RID: 338 RVA: 0x00006E78 File Offset: 0x00006278
		public ModuleLoadException(string message)
			: base(message)
		{
		}

		// Token: 0x04000091 RID: 145
		public const string Nested = "A nested exception occurred after the primary exception that caused the C++ module to fail to load.\n";
	}
}
