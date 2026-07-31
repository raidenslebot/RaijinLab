using System;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;

namespace msclr.interop
{
	// Token: 0x02000004 RID: 4
	internal class context_node<wchar_t\u0020const\u0020*,System::String\u0020^> : context_node_base, IDisposable
	{
		// Token: 0x06000123 RID: 291 RVA: 0x00005C24 File Offset: 0x00005024
		public unsafe context_node<wchar_t\u0020const\u0020*,System::String\u0020^>(char** _to_object, string _from_object)
		{
			IntPtr intPtr = Marshal.StringToHGlobalUni(_from_object);
			this._ip = intPtr;
			*_to_object = this._ip.ToPointer();
		}

		// Token: 0x06000124 RID: 292 RVA: 0x00005E44 File Offset: 0x00005244
		private void ~context_node<wchar_t\u0020const\u0020*,System::String\u0020^>()
		{
			this.!context_node<wchar_t\u0020const\u0020*,System::String\u0020^>();
		}

		// Token: 0x06000125 RID: 293 RVA: 0x00005C54 File Offset: 0x00005054
		private void !context_node<wchar_t\u0020const\u0020*,System::String\u0020^>()
		{
			if (this._ip != IntPtr.Zero)
			{
				Marshal.FreeHGlobal(this._ip);
			}
		}

		// Token: 0x06000126 RID: 294 RVA: 0x00005E58 File Offset: 0x00005258
		[HandleProcessCorruptedStateExceptions]
		protected virtual void Dispose([MarshalAs(UnmanagedType.U1)] bool A_0)
		{
			if (A_0)
			{
				this.!context_node<wchar_t\u0020const\u0020*,System::String\u0020^>();
			}
			else
			{
				try
				{
					this.!context_node<wchar_t\u0020const\u0020*,System::String\u0020^>();
				}
				finally
				{
					base.Finalize();
				}
			}
		}

		// Token: 0x06000127 RID: 295 RVA: 0x00005EE8 File Offset: 0x000052E8
		public sealed void Dispose()
		{
			this.Dispose(true);
			GC.SuppressFinalize(this);
		}

		// Token: 0x06000128 RID: 296 RVA: 0x00005E9C File Offset: 0x0000529C
		protected override void Finalize()
		{
			this.Dispose(false);
		}

		// Token: 0x04000083 RID: 131
		private IntPtr _ip;
	}
}
