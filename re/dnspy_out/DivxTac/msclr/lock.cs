using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace msclr
{
	// Token: 0x02000008 RID: 8
	internal class @lock : IDisposable
	{
		// Token: 0x0600012F RID: 303 RVA: 0x00001498 File Offset: 0x00000898
		public @lock(lockRef _object)
		{
			this.acquire(-1);
		}

		// Token: 0x06000130 RID: 304 RVA: 0x000017F0 File Offset: 0x00000BF0
		private void ~lock()
		{
			this.release();
		}

		// Token: 0x06000131 RID: 305 RVA: 0x000012C8 File Offset: 0x000006C8
		[return: MarshalAs(UnmanagedType.U1)]
		public bool is_locked()
		{
			return this.m_locked;
		}

		// Token: 0x06000132 RID: 306 RVA: 0x000012DC File Offset: 0x000006DC
		public implicit operator string()
		{
			return (!this.m_locked) ? _detail_class._safe_false : _detail_class._safe_true;
		}

		// Token: 0x06000133 RID: 307 RVA: 0x00001378 File Offset: 0x00000778
		public void acquire(TimeSpan _timeout)
		{
			if (!this.m_locked)
			{
				Monitor.TryEnter(this.m_object, _timeout, ref this.m_locked);
				if (!this.m_locked)
				{
					throw Marshal.GetExceptionForHR(-2147024638);
				}
			}
		}

		// Token: 0x06000134 RID: 308 RVA: 0x0000133C File Offset: 0x0000073C
		public void acquire()
		{
			if (!this.m_locked)
			{
				Monitor.TryEnter(this.m_object, -1, ref this.m_locked);
				if (!this.m_locked)
				{
					throw Marshal.GetExceptionForHR(-2147024638);
				}
			}
		}

		// Token: 0x06000135 RID: 309 RVA: 0x00001300 File Offset: 0x00000700
		public void acquire(int _timeout)
		{
			if (!this.m_locked)
			{
				Monitor.TryEnter(this.m_object, _timeout, ref this.m_locked);
				if (!this.m_locked)
				{
					throw Marshal.GetExceptionForHR(-2147024638);
				}
			}
		}

		// Token: 0x06000136 RID: 310 RVA: 0x000013E8 File Offset: 0x000007E8
		[return: MarshalAs(UnmanagedType.U1)]
		public bool try_acquire(TimeSpan _timeout)
		{
			if (!this.m_locked)
			{
				Monitor.TryEnter(this.m_object, _timeout, ref this.m_locked);
				if (!this.m_locked)
				{
					return false;
				}
			}
			return true;
		}

		// Token: 0x06000137 RID: 311 RVA: 0x000013B4 File Offset: 0x000007B4
		[return: MarshalAs(UnmanagedType.U1)]
		public bool try_acquire(int _timeout)
		{
			if (!this.m_locked)
			{
				Monitor.TryEnter(this.m_object, _timeout, ref this.m_locked);
				if (!this.m_locked)
				{
					return false;
				}
			}
			return true;
		}

		// Token: 0x06000138 RID: 312 RVA: 0x0000141C File Offset: 0x0000081C
		public void release()
		{
			if (this.m_locked)
			{
				Monitor.Exit(this.m_object);
				this.m_locked = false;
			}
		}

		// Token: 0x06000139 RID: 313 RVA: 0x00001804 File Offset: 0x00000C04
		protected virtual void Dispose([MarshalAs(UnmanagedType.U1)] bool A_0)
		{
			if (A_0)
			{
				this.release();
			}
			else
			{
				base.Finalize();
			}
		}

		// Token: 0x0600013A RID: 314 RVA: 0x00001B5C File Offset: 0x00000F5C
		public sealed void Dispose()
		{
			this.Dispose(true);
			GC.SuppressFinalize(this);
		}

		// Token: 0x04000088 RID: 136
		private object m_object = _object;

		// Token: 0x04000089 RID: 137
		private bool m_locked = false;
	}
}
