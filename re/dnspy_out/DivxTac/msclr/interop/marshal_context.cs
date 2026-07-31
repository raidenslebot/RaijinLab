using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace msclr.interop
{
	// Token: 0x02000005 RID: 5
	internal class marshal_context : IDisposable
	{
		// Token: 0x0600012A RID: 298 RVA: 0x00005CA8 File Offset: 0x000050A8
		private void ~marshal_context()
		{
			LinkedList<object>.Enumerator enumerator = this._clean_up_list.GetEnumerator();
			if (enumerator.MoveNext())
			{
				do
				{
					IDisposable disposable = enumerator.Current as IDisposable;
					if (disposable != null)
					{
						disposable.Dispose();
					}
				}
				while (enumerator.MoveNext());
			}
		}

		// Token: 0x0600012B RID: 299 RVA: 0x00005CEC File Offset: 0x000050EC
		protected virtual void Dispose([MarshalAs(UnmanagedType.U1)] bool A_0)
		{
			if (A_0)
			{
				this.~marshal_context();
			}
			else
			{
				base.Finalize();
			}
		}

		// Token: 0x0600012C RID: 300 RVA: 0x00005EB0 File Offset: 0x000052B0
		public sealed void Dispose()
		{
			this.Dispose(true);
			GC.SuppressFinalize(this);
		}

		// Token: 0x04000084 RID: 132
		internal readonly LinkedList<object> _clean_up_list = new LinkedList<object>();
	}
}
