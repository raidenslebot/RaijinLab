using System;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using msclr.interop.details;

namespace msclr.interop
{
	// Token: 0x02000003 RID: 3
	internal class context_node<char\u0020const\u0020*,System::String\u0020^> : context_node_base, IDisposable
	{
		// Token: 0x0600011D RID: 285 RVA: 0x00005D20 File Offset: 0x00005120
		public unsafe context_node<char\u0020const\u0020*,System::String\u0020^>(sbyte** _to_object, string _from_object)
		{
			this._ptr = null;
			char_buffer<char> char_buffer<char>;
			if (_from_object == null)
			{
				*_to_object = 0;
			}
			else
			{
				uint num = <Module>.msclr.interop.details.GetAnsiStringSize(_from_object);
				char_buffer<char> = 0;
				sbyte* ptr = <Module>.new[](num);
				char_buffer<char> = ptr;
				try
				{
					if (ptr == null)
					{
						throw new InsufficientMemoryException();
					}
					<Module>.msclr.interop.details.WriteAnsiString(ptr, num, _from_object);
					char_buffer<char> = 0;
					this._ptr = ptr;
					*_to_object = ptr;
				}
				catch
				{
					<Module>.___CxxCallUnwindDtor(ldftn(msclr.interop.details.char_buffer<char>.{dtor}), (void*)(&char_buffer<char>));
					throw;
				}
				<Module>.delete[](null);
				GC.KeepAlive(this);
			}
			try
			{
			}
			catch
			{
				<Module>.___CxxCallUnwindDtor(ldftn(msclr.interop.details.char_buffer<char>.{dtor}), (void*)(&char_buffer<char>));
				throw;
			}
		}

		// Token: 0x0600011E RID: 286 RVA: 0x00005C04 File Offset: 0x00005004
		private unsafe void ~context_node<char\u0020const\u0020*,System::String\u0020^>()
		{
			<Module>.delete[]((void*)this._ptr);
			GC.KeepAlive(this);
		}

		// Token: 0x0600011F RID: 287 RVA: 0x00005C04 File Offset: 0x00005004
		private unsafe void !context_node<char\u0020const\u0020*,System::String\u0020^>()
		{
			<Module>.delete[]((void*)this._ptr);
			GC.KeepAlive(this);
		}

		// Token: 0x06000120 RID: 288 RVA: 0x00005DE0 File Offset: 0x000051E0
		[HandleProcessCorruptedStateExceptions]
		protected unsafe virtual void Dispose([MarshalAs(UnmanagedType.U1)] bool A_0)
		{
			if (A_0)
			{
				<Module>.delete[]((void*)this._ptr);
				GC.KeepAlive(this);
			}
			else
			{
				try
				{
					this.!context_node<char\u0020const\u0020*,System::String\u0020^>();
				}
				finally
				{
					base.Finalize();
				}
			}
		}

		// Token: 0x06000121 RID: 289 RVA: 0x00005ECC File Offset: 0x000052CC
		public sealed void Dispose()
		{
			this.Dispose(true);
			GC.SuppressFinalize(this);
		}

		// Token: 0x06000122 RID: 290 RVA: 0x00005E30 File Offset: 0x00005230
		protected override void Finalize()
		{
			this.Dispose(false);
		}

		// Token: 0x04000082 RID: 130
		private unsafe sbyte* _ptr;
	}
}
